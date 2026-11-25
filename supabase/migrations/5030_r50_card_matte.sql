-- 5030 (release 50; docs/changes/2026-11-25-r50-car-cards.md): the car cards' drive-off cut from the studio render itself.
-- Why no card drove off: the drive-off needs the cover's side cutout (3150: site_cutouts, shot left, cut by rembg and sharp).
-- Since 3701 the cover is the studio side render, and its cutout was made only by the background remover, which runs only
-- on the company server (REMBG_URL, sharp); the listing worker runs in the Cloudflare Worker, where every run answered
-- "sharp is not installed" and nothing was cut. Now the worker cuts a matte from the render against the scene's plate
-- (web/src/features/listing/studio-matte.ts): a small PNG whose alpha is the car, and the plate cropped like the render.
--   1. site_cutouts.kind ('cutout' from rembg, 'matte' from the plate), plate_path, box (the car's box in the frame).
--   2. app.site_cutout_source: a studio render's plate (showroom.background), the gate's crop window and car box.
--   3. app.site_cutouts_due: a studio render with a plate and only an older rembg cutout is due for its matte.
--   4. app.site_cutout_save keeps kind, plate and box; app.photo_side_cutout gives them to the listing row (cover.cutout).
-- SCHEMA_MARKER 5030.
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
  if position(p_old in d) = 0 then raise exception '5030: the text to change was not found in %: %', p_sig, left(p_old, 160); end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. the matte's columns
alter table site_cutouts
  add column if not exists kind text not null default 'cutout' check (kind in ('cutout', 'matte')),
  add column if not exists plate_path text check (plate_path is null or (plate_path ~ '^site/cutouts/' and plate_path !~ '\.\.')),
  add column if not exists box jsonb check (box is null or jsonb_typeof(box) = 'object');
comment on column site_cutouts.kind is 'Release 50 (5030): cutout = a transparent WebP of the car (rembg, 3080); matte = a PNG in the render''s own frame whose alpha is the car, cut against the scene''s plate (the cards'' drive-off).';
comment on column site_cutouts.plate_path is 'Release 50 (5030): a matte''s plate, cropped like the render: what the card shows behind the car once it has driven off.';
comment on column site_cutouts.box is 'Release 50 (5030): the car''s box in the render (fractions x, y, w, h), from the studio gate.';

-- ================================================================ 2. where a matte comes from
create or replace function app.site_cutout_source(p_vehicle uuid, p_shot text default 'left') returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select jsonb_build_object('kind', 'studio', 'bucket', 'vehicle-public', 'path', ph.processed_path, 'facing', app.site_cutout_facing(ph.shot_type))
         || case when nullif(ph.showroom ->> 'background', '') is not null and ph.r45 #> '{gate,win}' is not null and ph.r45 #> '{gate,measures,car}' is not null
                 then jsonb_build_object('plate', ph.showroom ->> 'background', 'win', ph.r45 #> '{gate,win}', 'box', ph.r45 #> '{gate,measures,car}')
                 else '{}'::jsonb end
    from vehicle_photos ph
   where ph.vehicle_id = p_vehicle and ph.shot_type = p_shot and app.photo_render_live(ph)
   order by ph.created_at desc limit 1
$$;

-- ================================================================ 3. due: an older rembg cutout of a render that can have its matte
select pg_temp.patch_fn('app.site_cutouts_due(integer, text)'::regprocedure,
  $q$and (k.vehicle_id is null or k.source_path is distinct from s.src ->> 'path' or (k.path is null and k.tries < 6))$q$,
  $q$and (k.vehicle_id is null or k.source_path is distinct from s.src ->> 'path' or (k.path is null and k.tries < 6)
            or (s.src ? 'plate' and k.kind <> 'matte' and k.tries < 6))$q$);

-- ================================================================ 4. kept, and handed to the listing row
alter function app.site_cutout_save(uuid, text, jsonb) rename to site_cutout_save_pre5030;
create function app.site_cutout_save(p_vehicle uuid, p_shot text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare r jsonb;
begin
  if nullif(p ->> 'path', '') is not null and coalesce(p ->> 'kind', 'cutout') = 'matte' then
    if nullif(p ->> 'plate', '') is null or p ->> 'plate' !~ '^site/cutouts/' or p ->> 'plate' ~ '\.\.' then
      raise exception 'A matte needs its plate' using errcode = '22023';
    end if;
  end if;
  r := app.site_cutout_save_pre5030(p_vehicle, p_shot, p);
  if coalesce((r ->> 'ok')::boolean, false) then
    update site_cutouts set kind = case when p ->> 'kind' = 'matte' then 'matte' else 'cutout' end,
           plate_path = case when p ->> 'kind' = 'matte' then p ->> 'plate' end,
           box = case when jsonb_typeof(p -> 'box') = 'object' then p -> 'box' end
     where vehicle_id = p_vehicle and shot = p_shot;
    -- the listing row was refreshed by the step before, without these: again
    begin perform app.listing_cache_refresh(array[p_vehicle]); exception when others then null; end;
  end if;
  return r;
end $$;
select pg_temp.copy_grants('app.site_cutout_save(uuid, text, jsonb)'::regprocedure, 'app.site_cutout_save_pre5030(uuid, text, jsonb)'::regprocedure);
revoke all on function app.site_cutout_save_pre5030(uuid, text, jsonb) from public, anon, authenticated;
grant execute on function app.site_cutout_save(uuid, text, jsonb) to service_role;

create or replace function app.photo_side_cutout(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('path', k.path, 'width', k.width, 'height', k.height, 'facing', k.facing, 'kind', k.kind)
         || case when k.kind = 'matte' then jsonb_build_object('plate', k.plate_path, 'box', k.box) else '{}'::jsonb end
    from site_cutouts k where k.vehicle_id = p_vehicle and k.shot = 'left' and nullif(k.path, '') is not null
$$;
grant execute on function app.photo_side_cutout(uuid) to service_role;
