-- 2210_r36b_social_video.sql
-- Release 36b, item 2. The owner: "it would be nice to be able to have it generate social media content as well, including
-- photos and videos."
--   1. A 9:16 short video of a car (a slideshow with a slow zoom and pan on each photo, the price a day, the call to action
--      and the brand), drawn in the person's browser on a canvas and recorded there (no paid service, no server rendering).
--      Made from the car's real approved photos on the site (never a generated view, a made cover or a private photo).
--   2. The words and timing are Program settings: social_video_cta, social_video_brand, social_video_seconds_per_photo and
--      social_video_max_photos. {price} in the call to action is the live price a day.
--   3. social_videos: each video saved to the public bucket (vehicles/<car>/social/<id>.mp4 or .webm), with who made it, kept
--      for download and for the post scheduler (2220). Admin, Fleet, customer service and Sales (app.marketing_may, 1053)
--      make and remove them; the door's ops_read social_video_kit and ops_do social_video_save / social_video_remove.
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

alter table program_settings
  add column if not exists social_video_cta text not null default 'From {price} a day · Book at carmacars.ca' check (length(social_video_cta) between 3 and 80),
  add column if not exists social_video_brand text not null default 'CarmaCars' check (length(social_video_brand) between 1 and 40),
  add column if not exists social_video_seconds_per_photo numeric(3,1) not null default 2.5 check (social_video_seconds_per_photo between 1.5 and 6),
  add column if not exists social_video_max_photos integer not null default 8 check (social_video_max_photos between 3 and 12);
comment on column program_settings.social_video_cta is 'Short video (2210): the call to action at the bottom of every short video; {price} is the live price a day (left out when the car has none).';
comment on column program_settings.social_video_brand is 'Short video (2210): the brand name at the top of every short video.';
comment on column program_settings.social_video_seconds_per_photo is 'Short video (2210): seconds each photo shows (1.5 to 6).';
comment on column program_settings.social_video_max_photos is 'Short video (2210): the most photos in one video (3 to 12); the cover first, then the site''s order.';

create table if not exists social_videos (
  id          uuid primary key default gen_random_uuid(),
  vehicle_id  uuid not null references vehicles (id) on delete cascade,
  path        text not null unique check (path ~ '^vehicles/[0-9a-f-]{36}/social/[0-9a-f-]{36}\.(mp4|webm)$'),
  mime        text not null check (mime in ('video/mp4', 'video/webm')),
  seconds     numeric(5,1) not null check (seconds > 0 and seconds <= 90),
  bytes       bigint not null check (bytes > 0 and bytes <= 15 * 1024 * 1024),
  price_cents bigint,
  created_by  uuid references users (id) on delete set null,
  created_at  timestamptz not null default now(),
  removed_at  timestamptz,
  check (split_part(path, '/', 2) = vehicle_id::text)
);
comment on table social_videos is 'Short videos (2210): a 9:16 slideshow of a car''s real approved photos with the price, the call to action and the brand, made in the browser and kept for download and the post scheduler.';
create index if not exists social_videos_vehicle on social_videos (vehicle_id, created_at desc) where removed_at is null;
create trigger audit_social_videos after insert or update or delete on social_videos for each row execute function app.audit_row();
alter table social_videos enable row level security;
create policy admin_all on social_videos for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on social_videos from public, anon, authenticated;
grant select on social_videos to authenticated;
grant all on social_videos to service_role;

-- what the browser needs to make a car's video: the photos (real, approved, on the site; the original order of 2100's
-- wrapped function, so never a made cover or a generated view), the name, the price and the words
create or replace function app.social_video_kit(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_vehicle uuid := nullif(p ->> 'vehicle', '')::uuid;
  ps program_settings := app.settings();
  s jsonb;
  v_price bigint;
  v_cta text;
begin
  if not app.marketing_may(p_by) then raise exception 'An Admin, Fleet, customer service or Sales makes social videos' using errcode = '42501'; end if;
  if v_vehicle is null or not exists (select 1 from vehicles where id = v_vehicle) then raise exception 'Unknown car' using errcode = 'P0002'; end if;
  s := app.ad_snapshot(v_vehicle);
  v_price := nullif((s ->> 'daily')::bigint, 0);
  v_cta := ps.social_video_cta;
  if v_cta like '%{price}%' then
    v_cta := case when v_price is null then btrim(regexp_replace(regexp_replace(v_cta, '[^·|]*\{price\}[^·|]*', ''), '^[\s·|]+|[\s·|]+$', '', 'g'))
                  else replace(v_cta, '{price}', app.ad_money(v_price)) end;
  end if;
  return jsonb_build_object('vehicle', v_vehicle, 'name', app.vehicle_name(v_vehicle), 'price_cents', v_price,
    'price', case when v_price is not null then app.ad_money(v_price) end, 'cta', v_cta, 'brand', ps.social_video_brand,
    'seconds_per_photo', ps.social_video_seconds_per_photo,
    'photos', coalesce((select jsonb_agg(e ->> 'path' order by k) from jsonb_array_elements(app.public_listing_photos_pre2100(v_vehicle)) with ordinality t(e, k)
                         where k <= ps.social_video_max_photos and coalesce(e ->> 'path', '') <> ''), '[]'::jsonb),
    'videos', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'path', x.path, 'mime', x.mime, 'seconds', x.seconds, 'bytes', x.bytes, 'at', x.created_at) order by x.created_at desc)
                         from (select * from social_videos where vehicle_id = v_vehicle and removed_at is null order by created_at desc limit 10) x), '[]'::jsonb));
end $$;

-- p: vehicle, path, mime, seconds, bytes (the file is already in the public bucket under the car's social folder)
create or replace function app.social_video_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_vehicle uuid := nullif(p ->> 'vehicle', '')::uuid; v_id uuid;
begin
  if not app.marketing_may(p_by) then raise exception 'An Admin, Fleet, customer service or Sales makes social videos' using errcode = '42501'; end if;
  if v_vehicle is null or not exists (select 1 from vehicles where id = v_vehicle) then raise exception 'Unknown car' using errcode = 'P0002'; end if;
  if coalesce(p ->> 'path', '') !~ ('^vehicles/' || v_vehicle || '/social/[0-9a-f-]{36}\.(mp4|webm)$') then raise exception 'The video is not in this car''s social folder' using errcode = '22023'; end if;
  insert into social_videos (vehicle_id, path, mime, seconds, bytes, price_cents, created_by)
  values (v_vehicle, p ->> 'path', p ->> 'mime', (p ->> 'seconds')::numeric, (p ->> 'bytes')::bigint, nullif((app.ad_snapshot(v_vehicle) ->> 'daily')::bigint, 0), p_by)
  returning id into v_id;
  return app.social_video_kit(p_by, jsonb_build_object('vehicle', v_vehicle)) || jsonb_build_object('saved', v_id);
end $$;

-- p: id
create or replace function app.social_video_remove(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare x social_videos;
begin
  if not app.marketing_may(p_by) then raise exception 'An Admin, Fleet, customer service or Sales makes social videos' using errcode = '42501'; end if;
  update social_videos set removed_at = now() where id = nullif(p ->> 'id', '')::uuid and removed_at is null returning * into x;
  if x.id is null then raise exception 'Unknown video' using errcode = 'P0002'; end if;
  return app.social_video_kit(p_by, jsonb_build_object('vehicle', x.vehicle_id));
end $$;

-- ================================================================ the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre2210;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if (p_call in ('ops_read', 'va_read') and p_name = 'social_video_kit') or (p_call in ('ops_do', 'va_do') and p_name in ('social_video_save', 'social_video_remove')) then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    p := coalesce(p, '{}'::jsonb) - '_va';
    return case p_name when 'social_video_kit' then app.social_video_kit(p_user, p) when 'social_video_save' then app.social_video_save(p_user, p)
                       else app.social_video_remove(p_user, p) end;
  end if;
  return app.door_pre2210(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre2210(uuid, text, text, text, jsonb)'::regprocedure);

do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['social_video_kit', 'social_video_save', 'social_video_remove', 'door_pre2210'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
