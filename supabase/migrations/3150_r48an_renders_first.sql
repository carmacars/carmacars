-- 3150 (release 48, part AN): every car rendered in the full photo-standard set, the side profile first, then its real
-- photos; renders live as soon as they pass the check; a one-shot backfill; the side cutout on the listing row.
-- The owner (Nov 20): "Every car's first photo is a clean side profile ... keep the existing front three-quarter as photo 2."
-- Then (same day): AI renders the full standard angle set of every car from that car's own photos (same colour, wheels and
-- trim), so every car looks identical in framing. Gallery: 1. every render in the standard order, the side profile first;
-- 2. then the car's real photos, each with its background replaced by AI with the same branded background. Renders go live
-- immediately (staff can make any of them again, take it off or put it back in the studio: 3030's photo_r48_angle); the
-- backfill does every published car and new cars get renders on upload; spend stays under the existing gate (Program
-- settings: the image model's daily limit less the reserve, app.photo_gemini_left); the real photos are never hidden.
--   1. app.photo_render_order(): left (the side profile, nose to the left), front_left, front, rear_left, rear, dashboard,
--      front_seats, rear_seats, trunk. app.photo_r45_angles() (immutable, used by the pipeline) is unchanged.
--   2. app.public_listing_photos: the car's passed renders in that order (generated: true, the first the cover), then its
--      real photos (their processed version: the branded background), in the car's own order (real: true). A car with no
--      render yet: 3030's gallery as before.
--   3. The listing row (cache, search, cards, feeds, sitemap): the cover is the gallery's first photo (the side render), and
--      cover.cutout is the car's side cutout (3080's site_cutouts, shot left: rembg) for the cards' drive-off; rendered
--      counts the renders (the car page's "Rendered photos" note).
--   4. The job (app.job_photo_r48, every 5 minutes): the backfill's cars first, then the most viewed; per pass: the side
--      profile of every car, then the front three-quarter, then the other angles; then, for a car whose renders are done, its
--      real photos' branded background (2840's r45 edit, Program settings listing_photo_real_bg_auto, on). Same room as
--      before: the batch less the steps due, and the image model's daily limit less the reserve.
--   5. The backfill (app.photo_render_backfill, public.photo_render_backfill for the service role, Admin: ops_do
--      photo_render_backfill): every published real car on the list, the switches on, the first batch queued now; read
--      its progress with ops_read photo_render_backfill.
--   6. A cutout saved (3080) refreshes the car's listing row.
-- SCHEMA_MARKER 3150. docs/changes/2026-11-20-r48-motion-covers-filters.md.
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

-- ================================================================ 1. the order of the renders
create function app.photo_render_order() returns text[] language sql immutable parallel safe as $$
  select array['left', 'front_left', 'front', 'rear_left', 'rear', 'dashboard', 'front_seats', 'rear_seats', 'trunk']
$$;
comment on function app.photo_render_order() is 'Release 48 AN (3150): the order of a car''s renders on the site: the side profile (nose to the left) first, the front three-quarter second.';

alter table program_settings add column if not exists listing_photo_real_bg_auto boolean not null default true;
comment on column program_settings.listing_photo_real_bg_auto is 'Release 48 AN (3150): once a car''s renders are made, its real photos get the same branded background (the r45 edit by the image model), within the daily limit. They follow the renders in the gallery.';

-- ================================================================ 2. the gallery: renders first, then the real photos
alter function app.public_listing_photos(uuid) rename to public_listing_photos_pre3150;
create function app.public_listing_photos(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with r as (
    select distinct on (x.shot_type) x.* from vehicle_photos x
     where x.vehicle_id = p_vehicle and x.r48 and x.replaced_at is null and x.status = 'approved' and x.is_public
       and nullif(x.processed_path, '') is not null and x.shot_type = any (app.photo_render_order())
     order by x.shot_type, x.created_at desc
  ), renders as (
    select jsonb_build_object('path', r.processed_path, 'variants', coalesce(r.variants, '[]'::jsonb),
             'alt', coalesce(nullif(r.alt_text, ''), app.vehicle_name(p_vehicle) || ', ' || lower(coalesce(st.label, r.shot_type))) || ' (rendered)',
             'width', r.width, 'height', r.height, 'shot', r.shot_type, 'label', coalesce(st.label, r.shot_type), 'generated', true) j,
           array_position(app.photo_render_order(), r.shot_type) k
      from r left join listing_shot_types st on st.code = r.shot_type
  ), reals as (
    select jsonb_build_object('path', ph.processed_path, 'variants', coalesce(ph.variants, '[]'::jsonb),
             'alt', coalesce(nullif(ph.alt_text, ''), app.vehicle_name(p_vehicle) || ', ' || lower(coalesce(st.label, 'photo'))),
             'width', ph.width, 'height', ph.height, 'shot', ph.shot_type, 'label', coalesce(st.label, 'Photo'), 'real', true) j,
           100 + row_number() over (order by ph.is_cover desc, ph.sort_order, ph.created_at, ph.id) k
      from vehicle_photos ph left join listing_shot_types st on st.code = ph.shot_type
     where ph.vehicle_id = p_vehicle and not ph.r48 and not coalesce(ph.ai_generated, false) and ph.replaced_at is null
       and ph.status = 'approved' and ph.is_public and nullif(ph.processed_path, '') is not null
       and coalesce(st.is_public, true)
  )
  select case when not exists (select 1 from renders) then app.public_listing_photos_pre3150(p_vehicle)
    else (select jsonb_agg(a.j || jsonb_build_object('is_cover', a.n = 1) order by a.n)
            from (select u.j, row_number() over (order by u.k) n
                    from (select j, k from renders union all
                          select j, k from reals where not exists (select 1 from renders r2 where r2.j ->> 'path' = reals.j ->> 'path')) u) a) end
$$;
select pg_temp.copy_grants('app.public_listing_photos(uuid)'::regprocedure, 'app.public_listing_photos_pre3150(uuid)'::regprocedure);

-- ================================================================ 3. the listing row: the side render the cover, its cutout
-- the car's side cutout (3080: rembg, nose to the left in the frame), null when none is made yet
create function app.photo_side_cutout(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('path', k.path, 'width', k.width, 'height', k.height, 'facing', k.facing)
    from site_cutouts k where k.vehicle_id = p_vehicle and k.shot = 'left' and nullif(k.path, '') is not null
$$;

create function app.photo_render_cover(p_vehicle uuid, r jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare g jsonb; n integer;
begin
  if r is null then return null; end if;
  g := app.public_listing_photos(p_vehicle);
  n := (select count(*) from jsonb_array_elements(coalesce(g, '[]'::jsonb)) e where coalesce((e ->> 'generated')::boolean, false));
  if n > 0 and nullif(g -> 0 ->> 'path', '') is not null then
    r := r || jsonb_build_object('cover', jsonb_build_object('path', g -> 0 ->> 'path', 'variants', coalesce(g -> 0 -> 'variants', '[]'::jsonb),
                                   'alt', coalesce(g -> 0 ->> 'alt', app.vehicle_name(p_vehicle)), 'shot', g -> 0 ->> 'shot', 'generated', true,
                                   'cutout', case when g -> 0 ->> 'shot' = 'left' then app.photo_side_cutout(p_vehicle) end),
                                 'sample_photos', false, 'rendered', n);
  elsif r -> 'cover' is not null and jsonb_typeof(r -> 'cover') = 'object' and not coalesce((r #>> '{cover,sample}')::boolean, false) then
    -- no render yet: the cover as before, with the side cutout only when the cover is the side photo the cutout was made from
    r := jsonb_set(r, '{cover,cutout}', coalesce((select app.photo_side_cutout(p_vehicle) from site_cutouts k
                                                    where k.vehicle_id = p_vehicle and k.shot = 'left' and k.source_path = r #>> '{cover,path}'), 'null'::jsonb));
  end if;
  return r;
end $$;

alter function app.public_listing_row_live(uuid) rename to public_listing_row_live_pre3150;
create function app.public_listing_row_live(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.photo_render_cover(p_vehicle, app.public_listing_row_live_pre3150(p_vehicle))
$$;
select pg_temp.copy_grants('app.public_listing_row_live(uuid)'::regprocedure, 'app.public_listing_row_live_pre3150(uuid)'::regprocedure);

alter function app.public_listing_row(uuid) rename to public_listing_row_pre3150;
create function app.public_listing_row(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.photo_render_cover(p_vehicle, app.public_listing_row_pre3150(p_vehicle))
$$;
select pg_temp.copy_grants('app.public_listing_row(uuid)'::regprocedure, 'app.public_listing_row_pre3150(uuid)'::regprocedure);

-- ================================================================ 4. the job
create table if not exists photo_render_backfill (
  vehicle_id uuid primary key references vehicles (id) on delete cascade,
  asked_by   uuid,
  asked_at   timestamptz not null default now(),
  done_at    timestamptz
);
comment on table photo_render_backfill is 'Release 48 AN (3150): the cars of the one-shot render backfill; the job does them before the others, and marks each done once its renders are made (or flagged) and its real photos are on the branded background.';
alter table photo_render_backfill enable row level security;
create policy admin_read on photo_render_backfill for select to authenticated using (app.is_admin());
revoke all on table photo_render_backfill from public, anon, authenticated;
grant select, insert, update, delete on table photo_render_backfill to service_role;

-- a car's real photos still to be put on the branded background (2840's rule: not yet made to the current standard)
create function app.photo_render_reals_due(p_vehicle uuid) returns setof uuid
language sql stable security definer set search_path = public, app as $$
  select ph.id from vehicle_photos ph
   where ph.vehicle_id = p_vehicle and not ph.r48 and not coalesce(ph.ai_generated, false) and app.photo_r45_applies(ph) and app.photo_r45_due(ph)
     and coalesce(ph.r45 ->> 'state', '') not in ('queued', 'flagged')
   order by app.photo_rank(ph.shot_type), ph.sort_order, ph.created_at, ph.id
$$;

alter function app.job_photo_r48() rename to job_photo_r48_pre3150;
create function app.job_photo_r48() returns text
language plpgsql security definer set search_path = public, app as $$
declare ps program_settings := app.settings(); v_room integer; r record; n integer := 0; b integer := 0; v_pass integer; v_shot text; v_ph uuid;
        v_due integer := app.photo_r48_due(); v_order text[] := app.photo_render_order();
begin
  perform app.marketing_next(x.vehicle_id) from (select distinct m.vehicle_id from vehicle_marketing_photos m where m.status = 'queued' and m.job_id is null and m.job_input is not null) x;
  -- the backfill's cars whose renders and real photos are all done
  update photo_render_backfill f set done_at = now()
   where f.done_at is null and app.photo_r48_car_done(f.vehicle_id) and not exists (select 1 from app.photo_render_reals_due(f.vehicle_id))
     and not exists (select 1 from listing_jobs j join vehicle_photos ph on ph.id = j.vehicle_photo_id
                      where ph.vehicle_id = f.vehicle_id and j.kind = 'photo_r45' and j.status in ('queued', 'running'));
  if not coalesce(ps.listing_photo_r48_auto, true) or not coalesce(ps.listing_showroom_ai, false) then return 'off'; end if;
  v_room := least(greatest(coalesce(ps.listing_photo_r45_batch, 12) - v_due, 0),
                  greatest(app.photo_gemini_left(coalesce(ps.listing_photo_r45_reserve, 50)) - v_due, 0));
  if v_room = 0 then return 'full or waiting for Gemini'; end if;
  -- pass 1: the side profile of every car (the cover); 2: the front three-quarter; 3: the other angles; 4: the real photos
  for v_pass in 1..4 loop
    for r in select c.vehicle_id from app.photo_r48_cars() with ordinality c(vehicle_id, listed_at, o)
               left join photo_render_backfill f on f.vehicle_id = c.vehicle_id and f.done_at is null
              order by (f.vehicle_id is not null) desc, c.o loop
      exit when n >= v_room;
      if v_pass < 4 then
        foreach v_shot in array case v_pass when 1 then array['left'] when 2 then array['front_left'] else v_order[3:] end loop
          exit when n >= v_room;
          if app.photo_r48_queue(null, r.vehicle_id, v_shot, false) is not null then n := n + 1; end if;
        end loop;
      elsif coalesce(ps.listing_photo_real_bg_auto, true) and app.photo_r48_car_done(r.vehicle_id) then
        for v_ph in select app.photo_render_reals_due(r.vehicle_id) loop
          exit when n >= v_room;
          if app.photo_r45_queue(null, v_ph, false) then n := n + 1; b := b + 1; end if;
        end loop;
      end if;
    end loop;
  end loop;
  return format('%s render step(s) queued, %s of them real photos'' backgrounds', n, b);
end $$;
select pg_temp.copy_grants('app.job_photo_r48()'::regprocedure, 'app.job_photo_r48_pre3150()'::regprocedure);

-- ================================================================ 5. the backfill
create function app.photo_render_backfill(p_by uuid default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_cars integer; v_first text;
begin
  if p_by is not null and not app.photo_r45_may(p_by) then raise exception 'An Admin or fleet starts the render backfill' using errcode = '42501'; end if;
  insert into photo_render_backfill (vehicle_id, asked_by)
  select v.id, p_by from vehicles v join vehicle_listings l on l.vehicle_id = v.id and l.status = 'published'
   where not coalesce(v.is_sample, false) and v.retired_at is null
  on conflict (vehicle_id) do update set asked_at = now(), asked_by = excluded.asked_by, done_at = null;
  get diagnostics v_cars = row_count;
  -- the switches the renders need (the spend stays under the image model's daily limit less the reserve)
  update program_settings set listing_photo_r48_auto = true, listing_showroom_ai = true, listing_photo_real_bg_auto = true
   where not (listing_photo_r48_auto and listing_showroom_ai and listing_photo_real_bg_auto);
  v_first := app.job_photo_r48();
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'photo_render_backfill', 'program_settings', 'photo_render_backfill', jsonb_build_object('cars', v_cars, 'first_run', v_first));
  return jsonb_build_object('cars', v_cars, 'first_run', v_first, 'left_today', app.photo_gemini_left(0));
end $$;

create function app.photo_render_backfill_read() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('cars', count(*), 'done', count(*) filter (where f.done_at is not null),
           'renders_live', (select count(*) from vehicle_photos ph join photo_render_backfill g on g.vehicle_id = ph.vehicle_id
                             where ph.r48 and ph.replaced_at is null and ph.status = 'approved' and ph.is_public),
           'flagged', (select count(*) from vehicle_photos ph join photo_render_backfill g on g.vehicle_id = ph.vehicle_id
                        where ph.r48 and ph.replaced_at is null and ph.r45 ->> 'state' = 'flagged'),
           'waiting', app.photo_r45_outstanding(), 'left_today', app.photo_gemini_left(0),
           'asked_at', max(f.asked_at))
    from photo_render_backfill f
$$;

create function public.photo_render_backfill() returns jsonb
language sql security definer set search_path = public, app as $$ select app.photo_render_backfill(null) $$;
revoke all on function public.photo_render_backfill() from public, anon, authenticated;
grant execute on function public.photo_render_backfill() to service_role;
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['photo_render_backfill', 'photo_render_backfill_read', 'photo_render_reals_due',
                                                                 'photo_render_cover', 'photo_side_cutout'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- the Admin's door: ops_do photo_render_backfill (starts it), ops_read photo_render_backfill (its progress)
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre3150;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call in ('ops_read', 'ops_do') and p_name = 'photo_render_backfill' then
    perform app.door_begin(p_user, p_aal);
    if not app.photo_r45_may(p_user) then raise exception 'An Admin or fleet runs the render backfill' using errcode = '42501'; end if;
    return case p_call when 'ops_do' then app.photo_render_backfill(p_user) else app.photo_render_backfill_read() end;
  end if;
  return app.door_pre3150(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre3150(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ 6. a saved cutout refreshes the listing row
alter function app.site_cutout_save(uuid, text, jsonb) rename to site_cutout_save_pre3150;
create function app.site_cutout_save(p_vehicle uuid, p_shot text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare r jsonb := app.site_cutout_save_pre3150(p_vehicle, p_shot, p);
begin
  if coalesce((r ->> 'ok')::boolean, false) then
    begin perform app.listing_cache_refresh(array[p_vehicle]); exception when others then null; end;
  end if;
  return r;
end $$;
select pg_temp.copy_grants('app.site_cutout_save(uuid, text, jsonb)'::regprocedure, 'app.site_cutout_save_pre3150(uuid, text, jsonb)'::regprocedure);

-- the listing cache holds the new galleries and covers now
do $$
begin
  perform app.listing_cache_refresh(array(select distinct ph.vehicle_id from vehicle_photos ph where ph.r48 and ph.status = 'approved' and ph.is_public));
exception when undefined_function then null;
end $$;
