-- 2400_r39_showroom_photos.sql (release 39)
-- Owner, Nov 11: "the showroom backgrounds behind the cut-out cars look fake". The drawn room (0990) gives way to real
-- photographs of dealership or studio interiors, licensed for commercial use (Wikimedia Commons: CC0, public domain or
-- CC BY with the author credited), fetched once by web/scripts/showroom-photos.mjs (the seo-photos workflow) with their
-- source and licence recorded. Until a photo is stored the drawn room stays (the fallback).
--   1. showroom_backgrounds: one row per photo (its file in the public bucket, author, licence, source, the floor line
--      where the wheels stand, how strongly its floor reflects). Admins read and switch them; the script writes them.
--   2. Program settings: listing_showroom_photo_bg (on), listing_showroom_car_width (0.70 of the frame),
--      listing_cutout_min_quality (0.60: a cut-out whose mask scores lower is not composited; the real photo is used).
--   3. app.listing_job_context: every job of a car carries `background` (the car's photo room: the same one for every
--      angle, chosen by the car) and `cutout` (the car width and the quality floor).
--   4. app.worker_listing_result: the showroom note of a photo keeps the mask's score, the room used, and whether the
--      original photo was used for a poor cut-out.
--   5. Self-QA after deploys (web/scripts/verify-live.mjs --selfqa): site_selfqa_runs keeps each run; server_site_selfqa
--      adds the database's own findings (listed cars on the studio stand-in while they have an uploaded photo, covers made
--      from a low quality cut-out), saves the run and sends the Admins the staff alert site_selfqa when anything is wrong.
-- No applied migration is edited.
set local check_function_bodies = off;

-- ================================================================ 1. the photo rooms
create table if not exists showroom_backgrounds (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique check (slug ~ '^[a-z0-9][a-z0-9-]{1,79}$'),
  title text not null check (length(title) between 1 and 300),
  storage_path text not null check (storage_path ~ '^site/backdrop/photos/[a-z0-9-]+\.jpg$'),
  width integer not null default 1800 check (width between 600 and 6000),
  height integer not null default 1200 check (height between 400 and 4000),
  source_url text not null check (source_url ~ '^https://'),
  author text not null check (length(author) between 1 and 300),
  author_url text check (author_url is null or author_url ~ '^https?://'),
  licence text not null check (licence ~ '^(CC0( 1\.0)?|Public domain|PD|CC BY [0-9.]+)$'),
  licence_url text check (licence_url is null or licence_url ~ '^https?://'),
  floor_line numeric(4,3) not null default 0.820 check (floor_line between 0.5 and 0.97),
  reflect numeric(4,3) not null default 0.120 check (reflect between 0 and 0.3),
  active boolean not null default true,
  sort integer not null default 100,
  fetched_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);
comment on table showroom_backgrounds is 'Photo rooms of the listing showroom (2400): real dealership or studio interiors from Wikimedia Commons (CC0, public domain or CC BY, credited), fetched once by web/scripts/showroom-photos.mjs. floor_line: the share of the frame''s height where the wheels stand; reflect: the floor''s reflection (0 none). No CC BY-SA, NC or ND.';
alter table showroom_backgrounds enable row level security;
drop policy if exists admin_read on showroom_backgrounds;
create policy admin_read on showroom_backgrounds for select to authenticated using (app.is_admin());
revoke all on showroom_backgrounds from anon, authenticated;
grant select on showroom_backgrounds to authenticated;
grant all on showroom_backgrounds to service_role;

-- ================================================================ 2. settings
alter table program_settings
  add column if not exists listing_showroom_photo_bg boolean not null default true,
  add column if not exists listing_showroom_car_width numeric(3,2) not null default 0.70 check (listing_showroom_car_width between 0.5 and 0.85),
  add column if not exists listing_cutout_min_quality numeric(3,2) not null default 0.60 check (listing_cutout_min_quality between 0 and 1);
comment on column program_settings.listing_showroom_photo_bg is 'Listing photos (2400): the showroom uses a real photographed room (showroom_backgrounds) when one is stored; off, or none stored: the drawn room.';
comment on column program_settings.listing_showroom_car_width is 'Listing photos (2400): the car''s share of the frame''s width in a photographed room (wheels on the room''s floor line).';
comment on column program_settings.listing_cutout_min_quality is 'Listing photos (2400): a cut-out whose mask scores below this (0 to 1: one clean piece, firm and smooth edges) is not composited; the real photo is used (its plates covered as every photo).';

-- the room of a car: the same for every angle of it (picked by the car among the active rooms)
create or replace function app.showroom_background_for(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with s as (select (app.settings()).listing_showroom_photo_bg as on_),
       b as (select row_number() over (order by sort, slug) - 1 as k, count(*) over () as n, *
               from showroom_backgrounds where active)
  select jsonb_build_object('slug', b.slug, 'path', b.storage_path, 'floor', b.floor_line, 'reflect', b.reflect)
    from b, s
   where s.on_ and p_vehicle is not null and b.k = (abs(hashtext(p_vehicle::text)::bigint) % b.n)
$$;
revoke all on function app.showroom_background_for(uuid) from public, anon, authenticated;
grant execute on function app.showroom_background_for(uuid) to service_role;

-- ================================================================ 3. the job context
create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

alter function app.listing_job_context(uuid) rename to listing_job_context_pre2400;
create function app.listing_job_context(p_job uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when q.x is null or jsonb_typeof(q.x) <> 'object' then q.x
              else q.x || jsonb_build_object(
                'background', app.showroom_background_for(nullif(q.x ->> 'vehicle_id', '')::uuid),
                'cutout', jsonb_build_object('car_width', s.listing_showroom_car_width, 'min_quality', s.listing_cutout_min_quality)) end
    from (select app.listing_job_context_pre2400(p_job) x) q, app.settings() s
$$;
select pg_temp.copy_grants('app.listing_job_context(uuid)'::regprocedure, 'app.listing_job_context_pre2400(uuid)'::regprocedure);

-- ================================================================ 4. the result keeps the mask's score and the room
alter function app.worker_listing_result(uuid, jsonb) rename to worker_listing_result_pre2400;
create function app.worker_listing_result(p_job uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare j listing_jobs; r jsonb; v_s jsonb := p -> 'output' -> 'showroom';
begin
  select * into j from listing_jobs where id = p_job;
  r := app.worker_listing_result_pre2400(p_job, p);
  if j.kind = 'process_photo' and j.vehicle_photo_id is not null and coalesce((p ->> 'ok')::boolean, false) and jsonb_typeof(v_s) = 'object' then
    update vehicle_photos
       set showroom = coalesce(showroom, jsonb_build_object('provider', coalesce(v_s ->> 'provider', 'local'), 'at', now()))
                      || jsonb_strip_nulls(jsonb_build_object(
                           'mask_quality', case when jsonb_typeof(v_s -> 'mask_quality') = 'number' then least(1, greatest(0, (v_s ->> 'mask_quality')::numeric)) end,
                           'background', left(v_s ->> 'background', 80),
                           'used_original', case when jsonb_typeof(v_s -> 'used_original') = 'boolean' then (v_s ->> 'used_original')::boolean end,
                           'reason', v_s ->> 'reason', 'note', left(v_s ->> 'note', 300)))
     where id = j.vehicle_photo_id;
  end if;
  return r;
end $$;
select pg_temp.copy_grants('app.worker_listing_result(uuid, jsonb)'::regprocedure, 'app.worker_listing_result_pre2400(uuid, jsonb)'::regprocedure);

-- ================================================================ 5. self-QA after deploys
create table if not exists site_selfqa_runs (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  sha text check (sha is null or sha ~ '^[0-9a-f]{4,40}$'),
  base text check (base is null or base ~ '^https?://'),
  status text not null check (status in ('pass', 'warn', 'fail')),
  fails jsonb not null default '[]' check (jsonb_typeof(fails) = 'array'),
  warns jsonb not null default '[]' check (jsonb_typeof(warns) = 'array'),
  ms integer check (ms is null or ms >= 0)
);
comment on table site_selfqa_runs is 'Self-QA after each deploy (2400; web/scripts/verify-live.mjs --selfqa): FAIL lines (a 5xx or Error 1101 on a key page) and WARN lines (stand-in with a real photo, stand-in lettering overflow, low quality cut-out as cover, empty sitemap, noindex on an indexable page). Admins read; staff alert site_selfqa.';
alter table site_selfqa_runs enable row level security;
drop policy if exists admin_read on site_selfqa_runs;
create policy admin_read on site_selfqa_runs for select to authenticated using (app.is_admin());
revoke all on site_selfqa_runs from anon, authenticated;
grant select on site_selfqa_runs to authenticated;
grant all on site_selfqa_runs to service_role;

insert into staff_alert_rules (rule, label, grp, who, tier, topic, wired, fixed, hint, sort)
values ('site_selfqa', 'Site self-check after a deploy found problems', 'Site', '{admin}', 'normal', 'alerts', true, false,
        'The deploy''s self-check (verify-live --selfqa): a key page failing, or listing photos and SEO problems to fix.', 131)
on conflict (rule) do nothing;

-- the database's findings: listed cars on the stand-in while they have a real photo uploaded, covers from a poor cut-out
create or replace function app.selfqa_db_findings(p_standin_slugs text[] default '{}') returns jsonb
language sql stable security definer set search_path = public, app as $$
  with s as (select (app.settings()).listing_cutout_min_quality as q),
  listed as (
    select l.vehicle_id, l.slug from vehicle_listings l join vehicles v on v.id = l.vehicle_id
     where l.status = 'published' and not v.is_sample and v.retired_at is null
  ),
  uploaded as (
    select distinct ph.vehicle_id from vehicle_photos ph where ph.replaced_at is null and coalesce(ph.original_path, '') <> ''
  ),
  standin as (
    select l.slug from listed l join uploaded u on u.vehicle_id = l.vehicle_id
     where l.slug = any (coalesce(p_standin_slugs, '{}'))
        or not exists (select 1 from vehicle_photos ph where ph.vehicle_id = l.vehicle_id and ph.is_public and ph.replaced_at is null and ph.processed_path is not null)
  ),
  lowmask as (
    select l.slug, (ph.showroom ->> 'mask_quality')::numeric as q from listed l
      join vehicle_photos ph on ph.vehicle_id = l.vehicle_id and ph.is_cover and ph.is_public and ph.replaced_at is null
     where jsonb_typeof(ph.showroom -> 'mask_quality') = 'number' and not coalesce((ph.showroom ->> 'used_original')::boolean, false)
       and (ph.showroom ->> 'mask_quality')::numeric < (select q from s)
  )
  select coalesce((select jsonb_agg(jsonb_build_object('check', 'standin_with_photo', 'detail', 'Listed car on the studio stand-in with a real photo uploaded: /cars/' || coalesce(slug, '?')) order by slug) from (select distinct slug from standin) x), '[]'::jsonb)
      || coalesce((select jsonb_agg(jsonb_build_object('check', 'low_mask_cover', 'detail', 'Cover made from a low quality cut-out (' || round(q, 2) || '): /cars/' || coalesce(slug, '?')) order by slug) from lowmask), '[]'::jsonb)
$$;
revoke all on function app.selfqa_db_findings(text[]) from public, anon, authenticated;
grant execute on function app.selfqa_db_findings(text[]) to service_role;

-- the script's report (p: sha, base, ms, fails [{check, detail}], warns [{check, detail}], standin_slugs [..]) with the
-- database's findings added; saved, and the Admins alerted once per commit when anything failed or warned
create or replace function app.server_site_selfqa(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_sha text := nullif(left(regexp_replace(lower(coalesce(p ->> 'sha', '')), '[^0-9a-f]', '', 'g'), 40), '');
  v_base text := case when coalesce(p ->> 'base', '') ~ '^https?://' then left(p ->> 'base', 200) end;
  v_slugs text[] := coalesce((select array_agg(left(x, 120)) from jsonb_array_elements_text(case when jsonb_typeof(p -> 'standin_slugs') = 'array' then p -> 'standin_slugs' else '[]' end) x), '{}');
  v_fails jsonb := (select coalesce(jsonb_agg(jsonb_build_object('check', left(e ->> 'check', 60), 'detail', left(e ->> 'detail', 300))), '[]')
                      from jsonb_array_elements(case when jsonb_typeof(p -> 'fails') = 'array' then p -> 'fails' else '[]' end) e where jsonb_typeof(e) = 'object');
  v_warns jsonb := (select coalesce(jsonb_agg(jsonb_build_object('check', left(e ->> 'check', 60), 'detail', left(e ->> 'detail', 300))), '[]')
                      from jsonb_array_elements(case when jsonb_typeof(p -> 'warns') = 'array' then p -> 'warns' else '[]' end) e where jsonb_typeof(e) = 'object');
  v_db jsonb := app.selfqa_db_findings(v_slugs);
  v_status text;
  v_id bigint;
begin
  v_warns := v_warns || v_db;
  v_status := case when jsonb_array_length(v_fails) > 0 then 'fail' when jsonb_array_length(v_warns) > 0 then 'warn' else 'pass' end;
  insert into site_selfqa_runs (sha, base, status, fails, warns, ms)
  values (v_sha, v_base, v_status, v_fails, v_warns, case when jsonb_typeof(p -> 'ms') = 'number' then greatest(0, least(86400000, (p ->> 'ms')::numeric))::integer end)
  returning id into v_id;
  if v_status <> 'pass' then
    perform app.staff_alert('site_selfqa', 'site_selfqa_run', null, coalesce(left(v_sha, 8), 'run' || v_id) || ':' || v_status,
      case when v_status = 'fail' then 'Site self-check failed after the deploy' else 'Site self-check: things to fix' end,
      left(jsonb_array_length(v_fails) || ' failing, ' || jsonb_array_length(v_warns) || ' to fix. '
           || coalesce((select string_agg(e ->> 'detail', '; ') from (select e from jsonb_array_elements(v_fails || v_warns) e limit 4) x), ''), 600),
      jsonb_build_object('path_admin', '/admin/listings'));
  end if;
  return jsonb_build_object('id', v_id, 'status', v_status, 'db', v_db);
end $$;
revoke all on function app.server_site_selfqa(jsonb) from public, anon, authenticated;
grant execute on function app.server_site_selfqa(jsonb) to service_role;

create or replace function public.server_site_selfqa(p jsonb) returns jsonb
language sql set search_path = public, app as $$ select app.server_site_selfqa(p) $$;
revoke all on function public.server_site_selfqa(jsonb) from public, anon, authenticated;
grant execute on function public.server_site_selfqa(jsonb) to service_role;
