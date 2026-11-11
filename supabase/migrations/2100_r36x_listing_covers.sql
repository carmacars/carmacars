-- 2100_r36x_listing_covers.sql
-- Release 36, helper X, task 1. The owner: "listing first-photo options per listing: (a) plain car (current), (b) with model:
-- the photo AI places an attractive model posed with the car, realistic car-show style; always fully clothed and clearly
-- adult, nothing explicit, (c) flyer/banner: first photo with text overlay like a flyer (price from live pricing, offer,
-- call to action, logo), rendered from settings, never hard-coded. Chosen per listing, switchable any time, for Facebook
-- Marketplace and site listings. Prompts stored as settings."
--   1. vehicle_listings.cover_style: plain (the default: the cover photo as it is), model or flyer. Switchable any time by an
--      Admin, Fleet, customer service or Sales (app.marketing_may, 1053), on the listing (ops_do / va_do listing_cover_set).
--   2. listing_covers: the made first photos of a car (one row a make): the style, the cover photo it was made from, the
--      status (queued, made, needs_gemini, failed), the file, and for a flyer the price and the key of what it shows.
--      The listing worker makes them (listing_jobs kinds cover_model and cover_flyer): the model cover through the image
--      model (Program settings listing_cover_model_prompt, the car kept the same car, a refusal leaves the plain cover),
--      the flyer drawn by the site itself on the cover photo from Program settings listing_cover_flyer (headline, offer,
--      call to action, badge, logo, colours; {car} {price} {weekly} {monthly} filled from the live price).
--   3. The site and Marketplace: app.public_listing_photos and app.public_listing_row (every car card, car page, the
--      Marketplace kit, the partner feed) put the made cover first when the listing's style asks for one and it is current:
--      a flyer whose price or words changed since it was made, or a cover made from another photo, is not shown (the
--      plain cover is) and is made again by app.job_listing_covers (every 10 minutes).
-- No applied migration is edited: public_listing_photos, public_listing_row, worker_listing_result and the door are wrapped.
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

-- ================================================================ 1. settings and the style
alter table program_settings
  add column if not exists listing_cover_model_prompt text not null default
    'Add one attractive, confident adult fashion model (clearly over 25) posing next to the car like a professional at an international auto show: a stylish, glamorous, fitted evening outfit, fully clothed, elegant and tasteful, nothing revealing, nothing explicit or suggestive. The model stands beside the front corner of the car, slightly turned towards the camera, one hand near the car without covering it, and never in front of the car, its wheels or its badge. Realistic people, real skin and fabric, natural pose and expression, professional car-show lighting, the same place and light as the image.'
    check (length(listing_cover_model_prompt) between 40 and 2000),
  add column if not exists listing_cover_flyer jsonb not null default
    '{"headline": "{car}", "offer": "From {price} a day", "cta": "Book at carmacars.ca", "badge": "Pickup or delivery", "logo": true, "band": "#0B0B0C", "accent": "#E10600", "text": "#FFFFFF"}'::jsonb;
alter table program_settings drop constraint if exists program_settings_listing_cover_flyer_check;
alter table program_settings add constraint program_settings_listing_cover_flyer_check check (
  jsonb_typeof(listing_cover_flyer) = 'object'
  and coalesce(length(listing_cover_flyer ->> 'headline'), 0) <= 60 and coalesce(length(listing_cover_flyer ->> 'offer'), 0) <= 60
  and coalesce(length(listing_cover_flyer ->> 'cta'), 0) <= 40 and coalesce(length(listing_cover_flyer ->> 'badge'), 0) <= 40
  and coalesce(listing_cover_flyer ->> 'band', '#000000') ~ '^#[0-9A-Fa-f]{6}$' and coalesce(listing_cover_flyer ->> 'accent', '#000000') ~ '^#[0-9A-Fa-f]{6}$'
  and coalesce(listing_cover_flyer ->> 'text', '#FFFFFF') ~ '^#[0-9A-Fa-f]{6}$');
comment on column program_settings.listing_cover_model_prompt is 'Listing first photo "with model" (2100): the image model''s words for the person added beside the car. Always fully clothed and clearly adult; the site adds its own rules on top (nothing explicit, the car unchanged).';
comment on column program_settings.listing_cover_flyer is 'Listing first photo "flyer" (2100): headline, offer, cta (call to action), badge (empty: none), logo (true/false), band, accent and text colours (#RRGGBB). {car}, {price} (the live price a day), {weekly} and {monthly} are filled for each car.';

alter table vehicle_listings add column if not exists cover_style text not null default 'plain' check (cover_style in ('plain', 'model', 'flyer'));
comment on column vehicle_listings.cover_style is 'The listing''s first photo (2100): plain (the cover photo as it is), model (the image model''s car-show photo with a model) or flyer (the cover with the flyer band); switchable any time, on the site and Marketplace.';

create table if not exists listing_covers (
  id          uuid primary key default gen_random_uuid(),
  vehicle_id  uuid not null references vehicles (id) on delete cascade,
  style       text not null check (style in ('model', 'flyer')),
  photo_id    uuid not null references vehicle_photos (id) on delete cascade,
  source_path text not null,
  status      text not null default 'queued' check (status in ('queued', 'made', 'needs_gemini', 'failed')),
  path        text,
  width       integer,
  height      integer,
  provider    text,
  note        text check (note is null or length(note) <= 300),
  price_cents bigint,
  flyer_key   text,
  job_id      uuid references listing_jobs (id) on delete set null,
  created_by  uuid references users (id),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  check (status <> 'made' or path is not null)
);
comment on table listing_covers is 'Made first photos of a listing (2100): with a model (the image model) or a flyer (drawn by the site from Program settings). The newest made one of the listing''s style is shown while current.';
create index if not exists listing_covers_vehicle on listing_covers (vehicle_id, style, created_at desc);
create trigger listing_covers_updated before update on listing_covers for each row execute function app.set_updated_at();
create trigger audit_listing_covers after insert or update or delete on listing_covers for each row execute function app.audit_row();
alter table listing_covers enable row level security;
create policy admin_all on listing_covers for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on listing_covers from public, anon, authenticated;
grant select on listing_covers to authenticated;
grant all on listing_covers to service_role;

alter table listing_jobs drop constraint if exists listing_jobs_kind_check;
alter table listing_jobs add constraint listing_jobs_kind_check check (kind in ('decode_vin', 'draft_copy', 'process_photo', 'resize', 'publish', 'marketing_photo', 'plate_redo',
  'cover_model', 'cover_flyer'));

-- ================================================================ 2. what a cover shows
-- the car's cover photo now (the one the site shows first)
create or replace function app.cover_photo(p_vehicle uuid) returns vehicle_photos
language sql stable security definer set search_path = public, app as $$
  select ph.* from vehicle_photos ph join listing_shot_types st on st.code = ph.shot_type
   where ph.vehicle_id = p_vehicle and ph.replaced_at is null and ph.status = 'approved' and ph.is_public and st.is_public and ph.processed_path is not null
   order by ph.is_cover desc, ph.sort_order, ph.created_at limit 1
$$;

-- the flyer's words for a car: the settings with {car}, {price}, {weekly}, {monthly} filled from the live price
create or replace function app.cover_flyer_spec(p_vehicle uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  f jsonb := (app.settings()).listing_cover_flyer;
  s jsonb := app.ad_snapshot(p_vehicle);
  v vehicles;
  k text;
  out jsonb := '{}'::jsonb;
  t text;
begin
  select * into v from vehicles where id = p_vehicle;
  foreach k in array array['headline', 'offer', 'cta', 'badge'] loop
    t := coalesce(f ->> k, '');
    t := replace(t, '{car}', btrim(concat_ws(' ', v.year::text, v.make, v.model)));
    t := replace(t, '{price}', coalesce(app.ad_money(nullif((s ->> 'daily')::bigint, 0)), ''));
    t := replace(t, '{weekly}', coalesce(app.ad_money(nullif((s ->> 'weekly')::bigint, 0)), ''));
    t := replace(t, '{monthly}', coalesce(app.ad_money(nullif((s ->> 'monthly')::bigint, 0)), ''));
    -- a line whose price is unknown (the car takes no requests) is left out rather than shown half empty
    if ((f ->> k) like '%{price}%' and coalesce((s ->> 'daily')::bigint, 0) <= 0) or ((f ->> k) like '%{weekly}%' and coalesce((s ->> 'weekly')::bigint, 0) <= 0)
       or ((f ->> k) like '%{monthly}%' and coalesce((s ->> 'monthly')::bigint, 0) <= 0) then t := ''; end if;
    out := out || jsonb_build_object(k, left(btrim(t), 60));
  end loop;
  return out || jsonb_build_object('logo', coalesce((f ->> 'logo')::boolean, true), 'band', coalesce(f ->> 'band', '#0B0B0C'),
    'accent', coalesce(f ->> 'accent', '#E10600'), 'text', coalesce(f ->> 'text', '#FFFFFF'), 'price_cents', nullif((s ->> 'daily')::bigint, 0));
end $$;

-- what a flyer must match to be current: its words and colours, and the photo it is drawn on
create or replace function app.cover_flyer_key(p_vehicle uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select md5(app.cover_flyer_spec(p_vehicle)::text || coalesce((app.cover_photo(p_vehicle)).processed_path, ''))
$$;

-- the made cover the site shows first, or null (plain, nothing made yet, or not current)
create or replace function app.listing_cover_shown(p_vehicle uuid) returns listing_covers
language sql stable security definer set search_path = public, app as $$
  select c.* from vehicle_listings l
    join listing_covers c on c.vehicle_id = l.vehicle_id and c.style = l.cover_style and c.status = 'made'
   where l.vehicle_id = p_vehicle and l.cover_style <> 'plain'
     and c.source_path = (app.cover_photo(p_vehicle)).processed_path
     and (c.style <> 'flyer' or c.flyer_key = app.cover_flyer_key(p_vehicle))
   order by c.created_at desc limit 1
$$;

-- ================================================================ 3. making one
-- queues the cover of the listing's style when none current is made or being made; p_force makes it again
create or replace function app.listing_cover_queue(p_vehicle uuid, p_by uuid default null, p_force boolean default false) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  l vehicle_listings;
  ph vehicle_photos := app.cover_photo(p_vehicle);
  v_intake uuid;
  v_id uuid;
  v_job uuid;
  v_key text;
  v_spec jsonb;
  s program_settings := app.settings();
begin
  select * into l from vehicle_listings where vehicle_id = p_vehicle;
  if l.vehicle_id is null or l.cover_style = 'plain' or ph.id is null then return null; end if;
  v_key := case when l.cover_style = 'flyer' then app.cover_flyer_key(p_vehicle) end;
  if not p_force and exists (select 1 from listing_covers c where c.vehicle_id = p_vehicle and c.style = l.cover_style and c.source_path = ph.processed_path
                               and (l.cover_style <> 'flyer' or c.flyer_key = v_key)
                               and (c.status = 'made' or (c.status = 'queued' and c.created_at > now() - interval '30 minutes')
                                    or (c.status = 'needs_gemini' and c.created_at > now() - interval '1 day'))) then
    return null;
  end if;
  v_intake := (select i.id from listing_intakes i where i.vehicle_id = p_vehicle order by i.created_at desc limit 1);
  if v_intake is null then return null; end if;
  v_spec := case when l.cover_style = 'flyer' then app.cover_flyer_spec(p_vehicle) end;
  insert into listing_covers (vehicle_id, style, photo_id, source_path, price_cents, flyer_key, created_by)
  values (p_vehicle, l.cover_style, ph.id, ph.processed_path, (v_spec ->> 'price_cents')::bigint, v_key, p_by) returning id into v_id;
  v_job := app.enqueue_listing_job(v_intake, 'cover_' || l.cover_style, ph.id, jsonb_build_object('cover', jsonb_build_object(
    'id', v_id, 'vehicle_id', p_vehicle, 'photo_id', ph.id, 'style', l.cover_style, 'source', ph.processed_path,
    'mask', coalesce(nullif(ph.cutout ->> 'mask', ''), ph.cutout ->> 'auto_mask'), 'adjust', coalesce(ph.cutout -> 'adjust', '{}'::jsonb),
    'model', (select v.model from vehicles v where v.id = p_vehicle),
    'prompt', case when l.cover_style = 'model' then s.listing_cover_model_prompt end,
    'flyer', v_spec)));
  update listing_covers set job_id = v_job where id = v_id;
  return v_id;
end $$;

-- p: vehicle, style (plain, model or flyer), remake (true: make it again even if current)
create or replace function app.listing_cover_set(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_vehicle uuid := nullif(p ->> 'vehicle', '')::uuid;
  v_style text := coalesce(nullif(p ->> 'style', ''), 'plain');
begin
  if not app.marketing_may(p_by) then raise exception 'An Admin, Fleet, customer service or Sales chooses the first photo' using errcode = '42501'; end if;
  if v_style not in ('plain', 'model', 'flyer') then raise exception 'The first photo is plain, with a model or a flyer' using errcode = '22023'; end if;
  if v_vehicle is null or not exists (select 1 from vehicle_listings where vehicle_id = v_vehicle) then raise exception 'Unknown listing' using errcode = 'P0002'; end if;
  update vehicle_listings set cover_style = v_style where vehicle_id = v_vehicle;
  if v_style <> 'plain' then
    if (app.cover_photo(v_vehicle)).id is null then raise exception 'This car has no cover photo on the site yet' using errcode = '23514'; end if;
    perform app.listing_cover_queue(v_vehicle, p_by, coalesce((p ->> 'remake')::boolean, false));
  end if;
  return app.listing_cover_read(p_by, jsonb_build_object('vehicle', v_vehicle));
end $$;

create or replace function app.listing_cover_read(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_vehicle uuid := nullif(p ->> 'vehicle', '')::uuid;
  l vehicle_listings;
  ph vehicle_photos;
  shown listing_covers;
begin
  if not app.marketing_may(p_by) then raise exception 'Not permitted' using errcode = '42501'; end if;
  select * into l from vehicle_listings where vehicle_id = v_vehicle;
  if l.vehicle_id is null then raise exception 'Unknown listing' using errcode = 'P0002'; end if;
  ph := app.cover_photo(v_vehicle);
  shown := app.listing_cover_shown(v_vehicle);
  return jsonb_build_object('vehicle', v_vehicle, 'style', l.cover_style, 'cover_photo', ph.processed_path, 'shown', shown.path,
    'flyer', app.cover_flyer_spec(v_vehicle),
    'covers', coalesce((select jsonb_agg(x order by x ->> 'style') from (
        select distinct on (c.style) jsonb_build_object('style', c.style, 'status', c.status, 'path', c.path, 'provider', c.provider, 'note', c.note,
                 'current', c.source_path = ph.processed_path and (c.style <> 'flyer' or c.flyer_key = app.cover_flyer_key(v_vehicle)), 'at', c.updated_at) x
          from listing_covers c where c.vehicle_id = v_vehicle order by c.style, c.created_at desc) q), '[]'::jsonb));
end $$;

-- the worker's answer: the cover made (or why not)
alter function app.worker_listing_result(uuid, jsonb) rename to worker_listing_result_pre2100;
create function app.worker_listing_result(p_job uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare j listing_jobs; r jsonb; c jsonb := p #> '{output,cover}';
begin
  select * into j from listing_jobs where id = p_job;
  r := app.worker_listing_result_pre2100(p_job, p);
  if j.kind in ('cover_model', 'cover_flyer') then
    update listing_covers x
       set status = case when not coalesce((p ->> 'ok')::boolean, false) then case when coalesce((p ->> 'retryable')::boolean, true) and (select status from listing_jobs where id = p_job) <> 'failed' then 'queued' else 'failed' end
                         when c ->> 'status' in ('made', 'needs_gemini', 'failed') and (c ->> 'status' <> 'made' or (c ->> 'path') ~ ('^vehicles/' || x.vehicle_id || '/cover/')) then c ->> 'status' else 'failed' end,
           path = case when c ->> 'status' = 'made' and (c ->> 'path') ~ ('^vehicles/' || x.vehicle_id || '/cover/') then c ->> 'path' end,
           width = nullif(c ->> 'width', '')::integer, height = nullif(c ->> 'height', '')::integer,
           provider = left(c ->> 'provider', 40), note = left(coalesce(c ->> 'note', case when not coalesce((p ->> 'ok')::boolean, false) then p ->> 'error' end), 300)
     where x.id = coalesce(nullif(c ->> 'id', '')::uuid, nullif(j.input #>> '{cover,id}', '')::uuid);
  end if;
  return r;
end $$;
select pg_temp.copy_grants('app.worker_listing_result(uuid, jsonb)'::regprocedure, 'app.worker_listing_result_pre2100(uuid, jsonb)'::regprocedure);

-- every 10 minutes: a flyer whose price or words changed, or a cover whose photo changed, is made again
create or replace function app.job_listing_covers() returns integer
language plpgsql security definer set search_path = public, app as $$
declare r record; n integer := 0;
begin
  for r in select l.vehicle_id from vehicle_listings l join vehicles v on v.id = l.vehicle_id
            where l.cover_style <> 'plain' and v.retired_at is null and app.listing_cover_shown(l.vehicle_id) is null limit 50
  loop
    if app.listing_cover_queue(r.vehicle_id, null, false) is not null then n := n + 1; end if;
  end loop;
  return n;
end $$;
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('carmacars-listing-covers', '*/10 * * * *', $q$select app.job_listing_covers()$q$);
  end if;
end $$;

-- ================================================================ 4. the site and Marketplace show it first
alter function app.public_listing_photos(uuid) rename to public_listing_photos_pre2100;
create function app.public_listing_photos(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when c.id is null then x.ph
              else jsonb_build_array(jsonb_build_object('path', c.path, 'variants', '[]'::jsonb, 'width', c.width, 'height', c.height, 'shot', 'cover_' || c.style,
                     'label', case c.style when 'model' then 'Cover' else 'Offer' end, 'is_cover', true,
                     'alt', coalesce((x.ph -> 0 ->> 'alt'), app.vehicle_name(p_vehicle))))
                   -- the plain cover stays in the gallery, right after the made one
                   || coalesce((select jsonb_agg(e || jsonb_build_object('is_cover', false)) from jsonb_array_elements(x.ph) with ordinality t(e, k) where k = 1 and coalesce((e ->> 'is_cover')::boolean, false)), '[]'::jsonb)
                   || coalesce((select jsonb_agg(e order by k) from jsonb_array_elements(x.ph) with ordinality t(e, k) where k > 1 or not coalesce((e ->> 'is_cover')::boolean, false)), '[]'::jsonb)
         end
    from (select app.public_listing_photos_pre2100(p_vehicle) ph) x
    left join lateral (select * from app.listing_cover_shown(p_vehicle) s where s.id is not null) c on true
$$;
select pg_temp.copy_grants('app.public_listing_photos(uuid)'::regprocedure, 'app.public_listing_photos_pre2100(uuid)'::regprocedure);

alter function app.public_listing_row(uuid) rename to public_listing_row_pre2100;
create function app.public_listing_row(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when r is null or c.id is null then r
              else r || jsonb_build_object('cover', jsonb_build_object('path', c.path, 'variants', '[]'::jsonb, 'alt', coalesce(r #>> '{cover,alt}', app.vehicle_name(p_vehicle)))) end
    from (select app.public_listing_row_pre2100(p_vehicle) r) x
    left join lateral (select * from app.listing_cover_shown(p_vehicle) s where s.id is not null) c on true
$$;
select pg_temp.copy_grants('app.public_listing_row(uuid)'::regprocedure, 'app.public_listing_row_pre2100(uuid)'::regprocedure);

-- ================================================================ the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre2100;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if (p_call in ('ops_read', 'va_read') and p_name = 'listing_cover') or (p_call in ('ops_do', 'va_do') and p_name = 'listing_cover_set') then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    p := coalesce(p, '{}'::jsonb) - '_va';
    return case p_name when 'listing_cover' then app.listing_cover_read(p_user, p) else app.listing_cover_set(p_user, p) end;
  end if;
  return app.door_pre2100(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre2100(uuid, text, text, text, jsonb)'::regprocedure);

do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['cover_photo', 'cover_flyer_spec', 'cover_flyer_key', 'listing_cover_shown', 'listing_cover_queue', 'listing_cover_set',
              'listing_cover_read', 'job_listing_covers', 'door_pre2100', 'worker_listing_result_pre2100', 'public_listing_photos_pre2100', 'public_listing_row_pre2100'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
