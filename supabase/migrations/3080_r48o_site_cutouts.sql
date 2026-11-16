-- 3080 (release 48, part O): real fleet cars, cut out, in the site's decorative sections and the home hero.
-- The owner (Nov 15): the decorative sections and the home hero (not the listings or the car cards) show a real fleet car
-- as a background-removed cutout at the exact angle, size and position of the current sample car photo, placed over the
-- section's own background (no dealership background), with a black gradient behind the text; the hero rotates through
-- real cars as it already did. The photos come from the R48 photo studio set (3030 photo_r48_cars, the 3040 studio
-- covers); then the listing photos, then the check-in and check-out photos, then the stock model photos; then the sample.
-- The cutout is made once and kept in Storage, by the local cut-out step (rembg, then sharp), never by Cloudflare's image
-- transformations (the site is leaving Cloudflare).
--   1. site_cutouts: one cutout per car and angle (the side profile, 'left', is the angle of every sample car of the
--      section photos), with the photo it was made from; a new source photo (a better step of the chain, or a new studio
--      view) makes it again, the old one stays on the site until the new one is saved.
--   2. app.site_cutout_source(car, shot): the chain above, the first photo found. A check-in or check-out photo is only taken
--      for a side view (no plate shows); a stock model photo only when its licence asks for no credit line (CC0 or public
--      domain: a cutout shown without a credit line must not need one).
--   3. app.site_cutouts_due(limit, shot) for the worker (web/src/server/site-cutouts.ts), app.site_cutout_save to keep the
--      result (or the failure: tried again after 1, 2, 4 ... hours, at most 6 tries for one source photo).
--   4. public.site_cutouts(shot, limit): the cutouts of published real cars, most viewed first (as site_studio_covers).
-- SCHEMA_MARKER 3080. docs/changes/2026-11-15-r48o-cutouts-forecast.md.
set local check_function_bodies = off;

-- ================================================================ 1. the cutouts
create table if not exists site_cutouts (
  vehicle_id    uuid not null references vehicles (id) on delete cascade,
  shot          text not null check (shot in ('left', 'front_left')),
  source_kind   text not null check (source_kind in ('studio', 'listing', 'handover', 'stock')),
  source_bucket text not null,
  source_path   text not null,
  path          text check (path is null or (path ~ '^site/cutouts/' and path !~ '\.\.')),
  width         integer check (width is null or width > 0),
  height        integer check (height is null or height > 0),
  facing        text not null default 'left' check (facing in ('left', 'right')),
  tries         integer not null default 0 check (tries >= 0),
  error         text,
  next_try_at   timestamptz,
  made_at       timestamptz,
  updated_at    timestamptz not null default now(),
  primary key (vehicle_id, shot)
);
comment on table site_cutouts is 'Release 48 O (3080): one background-removed cutout per real car and angle for the site''s decorative sections and the home hero, made once by the local cut-out step (rembg, sharp) and kept in Storage (vehicle-public, site/cutouts/).';
comment on column site_cutouts.path is 'The cutout (WebP with transparency) in the public bucket; null until the first one is made. A remade cutout replaces it only once it is saved.';
comment on column site_cutouts.facing is 'Where the car''s nose points in the cutout: a section whose sample car faces the other way shows it mirrored.';
alter table site_cutouts enable row level security;
create policy admin_all on site_cutouts for select to authenticated using (app.is_admin());
create trigger audit_site_cutouts after insert or update or delete on site_cutouts for each row execute function app.audit_row();
revoke all on table site_cutouts from public, anon, authenticated;
grant select, insert, update, delete on table site_cutouts to service_role;

-- ================================================================ 2. where the photo comes from
-- the facing of a shot: the nose to the left for the left side and the front three-quarter (the r48 standard)
create function app.site_cutout_facing(p_shot text) returns text language sql immutable parallel safe as $$
  select case when p_shot in ('right', 'front_right', 'rear_left') then 'right' else 'left' end
$$;
-- the shots that show the same angle (the other side, mirrored)
create function app.site_cutout_shots(p_shot text) returns text[] language sql immutable parallel safe as $$
  select case p_shot when 'left' then array['left', 'right'] when 'front_left' then array['front_left', 'front_right'] else array[p_shot] end
$$;

create function app.site_cutout_source(p_vehicle uuid, p_shot text default 'left') returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(
    -- a. the R48 studio set (3030): the generated view of this angle, on the site (for the front three-quarter: the studio
    --    cover of 3040)
    (select jsonb_build_object('kind', 'studio', 'bucket', 'vehicle-public', 'path', ph.processed_path, 'facing', app.site_cutout_facing(ph.shot_type))
       from vehicle_photos ph
      where ph.vehicle_id = p_vehicle and ph.r48 and ph.shot_type = p_shot and ph.replaced_at is null and ph.status = 'approved' and ph.is_public
        and nullif(ph.processed_path, '') is not null and ph.processed_path !~ '^/'
      order by ph.created_at desc limit 1),
    -- b. the listing photos of this angle (either side), on the site
    (select jsonb_build_object('kind', 'listing', 'bucket', 'vehicle-public', 'path', ph.processed_path, 'facing', app.site_cutout_facing(ph.shot_type))
       from vehicle_photos ph
      where ph.vehicle_id = p_vehicle and not ph.r48 and ph.shot_type = any (app.site_cutout_shots(p_shot)) and ph.replaced_at is null
        and ph.status = 'approved' and ph.is_public and not coalesce(ph.ai_generated, false)
        and nullif(ph.processed_path, '') is not null and ph.processed_path !~ '^/'
      order by ph.shot_type = p_shot desc, ph.is_cover desc, ph.sort_order, ph.created_at desc limit 1),
    -- c. the check-in and check-out photos (a side view only: no plate shows), the newest first
    (select jsonb_build_object('kind', 'handover', 'bucket', p.storage_bucket, 'path', p.storage_path, 'facing', app.site_cutout_facing(p.shot))
       from condition_reports r join condition_report_photos p on p.condition_report_id = r.id
      where p_shot = 'left' and r.vehicle_id = p_vehicle and p.shot in ('left', 'right') and nullif(p.storage_path, '') is not null
      order by p.shot = 'left' desc, r.performed_at desc nulls last, p.taken_at desc limit 1),
    -- d. the stock photo of the model (a licence that asks for no credit line)
    (select jsonb_build_object('kind', 'stock', 'bucket', 'vehicle-public', 'path', app.photo_r48_stock(p_vehicle), 'facing', 'left')
      where app.photo_r48_stock(p_vehicle) is not null
        and exists (select 1 from vehicles v join vehicle_stock_photos s on s.kind = 'model' and s.status = 'active'
                     and s.make = app.photo_r48_slug(v.make) and (app.photo_r48_slug(v.model) = s.model or app.photo_r48_slug(v.model) like s.model || '-%')
                     and app.photo_r48_stock(p_vehicle) = s.path || '-' || (select max(z) from unnest(s.sizes) z) || '.webp'
                     and (s.licence ilike 'cc0%' or s.licence ilike '%public domain%' or s.licence ilike 'pd%')
                   where v.id = p_vehicle)))
$$;

-- the real cars on the site (the cars site_studio_covers takes), most viewed first
create function app.site_cutout_cars() returns table (vehicle_id uuid, o bigint)
language sql stable security definer set search_path = public, app as $$
  select v.id, row_number() over (order by l.pinned_rank nulls last, coalesce(t.score, 0) desc, v.id)
    from vehicles v
    join vehicle_listings l on l.vehicle_id = v.id and l.status = 'published'
    left join app.fleet_trend t on t.vehicle_id = v.id
   where not coalesce(v.is_sample, false) and v.retired_at is null
$$;

-- ================================================================ 3. the worker
-- the cars whose cutout is missing or was made from another photo than the chain now gives, a failure waiting its turn left
-- out; the most viewed cars first
create function app.site_cutouts_due(p_limit integer default 4, p_shot text default 'left') returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(x.j order by x.o), '[]'::jsonb) from (
    select jsonb_build_object('vehicle_id', c.vehicle_id, 'shot', p_shot, 'source', s.src, 'name', app.vehicle_name(c.vehicle_id)) j, c.o
      from app.site_cutout_cars() c
      cross join lateral (select app.site_cutout_source(c.vehicle_id, p_shot) src) s
      left join site_cutouts k on k.vehicle_id = c.vehicle_id and k.shot = p_shot
     where s.src is not null
       and (k.vehicle_id is null or k.source_path is distinct from s.src ->> 'path' or (k.path is null and k.tries < 6))
       and (k.next_try_at is null or k.next_try_at <= now() or k.source_path is distinct from s.src ->> 'path')
     order by c.o limit least(greatest(coalesce(p_limit, 4), 1), 20)) x
$$;

-- p: {source: {kind, bucket, path, facing}, path, width, height} when made; {source, error} when it failed
create function app.site_cutout_save(p_vehicle uuid, p_shot text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare k site_cutouts; s jsonb := p -> 'source';
begin
  if s is null or nullif(s ->> 'path', '') is null then raise exception 'The source photo is missing' using errcode = '22023'; end if;
  select * into k from site_cutouts where vehicle_id = p_vehicle and shot = p_shot for update;
  if nullif(p ->> 'path', '') is not null then
    insert into site_cutouts (vehicle_id, shot, source_kind, source_bucket, source_path, path, width, height, facing, tries, error, next_try_at, made_at, updated_at)
    values (p_vehicle, p_shot, s ->> 'kind', s ->> 'bucket', s ->> 'path', p ->> 'path', (p ->> 'width')::integer, (p ->> 'height')::integer,
            coalesce(s ->> 'facing', 'left'), 0, null, null, now(), now())
    on conflict (vehicle_id, shot) do update set source_kind = excluded.source_kind, source_bucket = excluded.source_bucket, source_path = excluded.source_path,
      path = excluded.path, width = excluded.width, height = excluded.height, facing = excluded.facing, tries = 0, error = null, next_try_at = null,
      made_at = now(), updated_at = now();
    return jsonb_build_object('ok', true, 'path', p ->> 'path');
  end if;
  -- a failure: the cutout on the site (made from an older photo) stays; the next try waits 1, 2, 4 ... hours
  insert into site_cutouts (vehicle_id, shot, source_kind, source_bucket, source_path, facing, tries, error, next_try_at)
  values (p_vehicle, p_shot, s ->> 'kind', s ->> 'bucket', s ->> 'path', coalesce(s ->> 'facing', 'left'), 1, left(coalesce(p ->> 'error', 'failed'), 300), now() + interval '1 hour')
  on conflict (vehicle_id, shot) do update set
    tries = case when site_cutouts.source_path = excluded.source_path then site_cutouts.tries + 1 else 1 end,
    error = excluded.error,
    next_try_at = now() + interval '1 hour' * power(2, least(case when site_cutouts.source_path = excluded.source_path then site_cutouts.tries else 0 end, 6)),
    -- the photo it is now made from is kept only once a cutout of it is saved (so the old cutout stays on the site)
    source_kind = case when site_cutouts.path is null then excluded.source_kind else site_cutouts.source_kind end,
    source_bucket = case when site_cutouts.path is null then excluded.source_bucket else site_cutouts.source_bucket end,
    source_path = case when site_cutouts.path is null then excluded.source_path else site_cutouts.source_path end,
    updated_at = now();
  return jsonb_build_object('ok', false);
end $$;

-- ================================================================ 4. the site's read
create function app.site_cutouts(p_shot text default 'left', p_limit integer default 12) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(x.j order by x.o), '[]'::jsonb) from (
    select jsonb_build_object('vehicle_id', k.vehicle_id, 'path', k.path, 'width', k.width, 'height', k.height, 'facing', k.facing,
             'kind', k.source_kind, 'alt', app.vehicle_name(k.vehicle_id)) j, c.o
      from app.site_cutout_cars() c join site_cutouts k on k.vehicle_id = c.vehicle_id and k.shot = p_shot
     where k.path is not null
     order by c.o limit least(greatest(coalesce(p_limit, 12), 1), 24)) x
$$;
create function public.site_cutouts(p_shot text default 'left', p_limit integer default 12) returns jsonb
language sql stable security definer set search_path = public, app as $$ select app.site_cutouts(p_shot, p_limit) $$;
comment on function public.site_cutouts(text, integer) is 'The cutouts of published real cars (3080) for the decorative sections and the home hero; public paths only.';
create function public.site_cutouts_due(p_limit integer default 4, p_shot text default 'left') returns jsonb
language sql stable security definer set search_path = public, app as $$ select app.site_cutouts_due(p_limit, p_shot) $$;
create function public.site_cutout_save(p_vehicle uuid, p_shot text, p jsonb) returns jsonb
language sql security definer set search_path = public, app as $$ select app.site_cutout_save(p_vehicle, p_shot, p) $$;

revoke all on function public.site_cutouts(text, integer), public.site_cutouts_due(integer, text), public.site_cutout_save(uuid, text, jsonb) from public, anon, authenticated;
grant execute on function public.site_cutouts(text, integer) to anon, authenticated, service_role;
grant execute on function public.site_cutouts_due(integer, text), public.site_cutout_save(uuid, text, jsonb) to service_role;
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['site_cutout_source', 'site_cutout_cars', 'site_cutouts_due', 'site_cutout_save', 'site_cutouts'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
