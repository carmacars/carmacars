-- 0137_seo_photos.sql
-- Licensed stock photos for the vehicle pages (docs/changes/2026-10-24-seo-photos.md). The owner, October 24, 2026:
-- the programmatic pages of every make, model, year and trim (and the place and service pages) mostly have no photo;
-- use properly licensed images, never scraped copyrighted photos.
--
-- 1. vehicle_stock_photos: one photo per make, model and generation (model years year_from to year_to; none for a
--    photo of the model in general), and a few generic photos per kind of place and service page (slot). Each with its
--    Wikimedia Commons file, author, licence (public domain, CC0, CC BY or CC BY-SA only: a check) and source, the
--    stored WebP widths in the public bucket (vehicle-public, seo-photos/...), and a status (active, hidden by an
--    Admin, pending a replacement, failed). Never a fleet car's photo: the fleet's photos stay in vehicle_photos.
-- 2. vehicle_stock_photo_checks (each model the pipeline has looked at: resumable runs and the coverage report) and
--    vehicle_stock_photo_runs (each run of .github/workflows/seo-photos.yml).
-- 3. The pages' reads: public.vehicle_stock_photo(make, model, year) (the generation of that model year; a model
--    page, the newest generation; a make page, its most popular model's) and public.stock_photos_generic(slot).
--    Program settings vpage_stock_photos (on by default) turns them off at once.
-- 4. The pipeline's calls (service role only): targets (fleet models first, then the popular list, then newest),
--    save a model, save a slot, the Admin's pending requests and their result, runs, coverage.
-- 5. Admin > Settings > Vehicle pages: the coverage, every photo by make, Hide, Show, Replace with a named Commons
--    file, Pick again (admin_read 'stock_photos', admin_do 'stock_photo').
-- 6. The guides.

-- ================================================================ 1. the photos
create table if not exists vehicle_stock_photos (
  id            uuid primary key default gen_random_uuid(),
  kind          text not null default 'model' check (kind in ('model', 'generic')),
  make          text check (make is null or make ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  model         text check (model is null or model ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  slot          text check (slot is null or slot ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  year_from     smallint check (year_from is null or year_from between 1900 and 2100),
  year_to       smallint check (year_to is null or year_to between 1900 and 2100),
  generation    text,
  wikidata      text check (wikidata is null or wikidata ~ '^Q[0-9]+$'),
  category      text,
  file_title    text not null check (file_title ~ '^File:.+'),
  source_url    text not null check (source_url ~ '^https://commons\.wikimedia\.org/[^[:space:]]+$'),
  author        text not null check (btrim(author) <> ''),
  author_url    text check (author_url is null or author_url ~ '^https://[^[:space:]]+$'),
  licence       text not null check (licence ~ '^(Public domain|CC0|CC BY( [0-9]\.[0-9])?|CC BY-SA( [0-9]\.[0-9])?)$'),
  licence_url   text check (licence_url is null or licence_url ~ '^https://[^[:space:]]+$'),
  alt           text,
  path          text check (path is null or path ~ '^seo-photos/[a-z0-9/-]+$'),
  sizes         smallint[] not null default '{}',
  width         integer check (width is null or width > 0),
  height        integer check (height is null or height > 0),
  sha1          text,
  score         numeric,
  status        text not null default 'active' check (status in ('active', 'hidden', 'pending', 'failed')),
  want_file     text,
  rejected_files text[] not null default '{}',
  picked_by     text not null default 'pipeline' check (picked_by in ('pipeline', 'admin')),
  note          text,
  checked_at    timestamptz not null default now(),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  updated_by    uuid references users (id),
  check ((year_from is null) = (year_to is null) and (year_to is null or year_to >= year_from)),
  check ((kind = 'model' and make is not null and model is not null and slot is null) or (kind = 'generic' and slot is not null and make is null and model is null)),
  -- shown only once stored
  check (status <> 'active' or (path is not null and cardinality(sizes) > 0 and width is not null and height is not null))
);
comment on table vehicle_stock_photos is 'Licensed stock photos (0137) for the vehicle pages (a make, model and generation) and the place and service pages (generic, by slot), from Wikimedia Commons: public domain, CC0, CC BY or CC BY-SA, always credited on the page. Never a fleet car''s photo.';
comment on column vehicle_stock_photos.path is 'The stored files without their width: <path>-<width>.webp in the vehicle-public bucket, for each width in sizes';
comment on column vehicle_stock_photos.want_file is 'An Admin asked for this Commons file instead (status pending): the next run checks its licence, stores it and makes it active';
comment on column vehicle_stock_photos.rejected_files is 'Files an Admin hid or asked to replace: never picked again for this make, model and generation';
create unique index if not exists vehicle_stock_photos_model_key on vehicle_stock_photos (make, model, coalesce(year_from, 0)) where kind = 'model';
create unique index if not exists vehicle_stock_photos_generic_key on vehicle_stock_photos (slot, file_title) where kind = 'generic';
create index if not exists vehicle_stock_photos_read on vehicle_stock_photos (make, model, year_from, year_to) where kind = 'model' and status = 'active';
create trigger vehicle_stock_photos_updated before update on vehicle_stock_photos for each row execute function app.set_updated_at();
create trigger audit_vehicle_stock_photos after insert or update or delete on vehicle_stock_photos for each row execute function app.audit_row();
alter table vehicle_stock_photos enable row level security;
create policy admin_all on vehicle_stock_photos for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on vehicle_stock_photos from anon, authenticated;
grant all on vehicle_stock_photos to service_role;

-- ================================================================ 2. checks and runs
create table if not exists vehicle_stock_photo_checks (
  make       text not null,
  model      text not null,
  wikidata   text,
  photos     integer not null default 0,
  note       text,
  run_id     uuid,
  checked_at timestamptz not null default now(),
  primary key (make, model)
);
comment on table vehicle_stock_photo_checks is 'Each catalog model the stock photo pipeline has looked at (0137), with what it found: the next run starts with the models not yet looked at.';
alter table vehicle_stock_photo_checks enable row level security;
create policy admin_all on vehicle_stock_photo_checks for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on vehicle_stock_photo_checks from anon, authenticated;
grant all on vehicle_stock_photo_checks to service_role;

create table if not exists vehicle_stock_photo_runs (
  id          uuid primary key default gen_random_uuid(),
  mode        text not null default 'write',
  run_url     text,
  started_at  timestamptz not null default now(),
  finished_at timestamptz,
  counts      jsonb,
  errors      jsonb
);
alter table vehicle_stock_photo_runs enable row level security;
create policy admin_all on vehicle_stock_photo_runs for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on vehicle_stock_photo_runs from anon, authenticated;
grant all on vehicle_stock_photo_runs to service_role;

alter table program_settings add column if not exists vpage_stock_photos boolean not null default true;
comment on column program_settings.vpage_stock_photos is 'Vehicle pages (0137): show the licensed stock photo of the make, model and generation (with its credit) instead of the studio drawing, and the generic photos on the place and service pages. On by default.';

-- ================================================================ 3. the pages' reads
create or replace function app.stock_photo_json(ph vehicle_stock_photos) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('id', ph.id, 'make', ph.make, 'model', ph.model, 'slot', ph.slot,
    'make_name', (select m.name from vehicle_catalog_makes m where m.slug = ph.make),
    'model_name', (select m.name from vehicle_catalog_models m where m.make_slug = ph.make and m.slug = ph.model),
    'year_from', ph.year_from, 'year_to', ph.year_to, 'generation', ph.generation, 'path', ph.path, 'sizes', to_jsonb(ph.sizes),
    'width', ph.width, 'height', ph.height, 'author', ph.author, 'author_url', ph.author_url, 'licence', ph.licence, 'licence_url', ph.licence_url,
    'source_url', ph.source_url, 'alt', ph.alt)
$$;

-- The photo for a vehicle page: the generation of that model year (never another generation's: a year no generation
-- covers keeps the studio drawing); a model page, the newest generation (or the model's general photo); a make page,
-- the photo of its most popular model. Null when there is none or the setting is off.
create or replace function public.vehicle_stock_photo(p_make text, p_model text default null, p_year integer default null) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when coalesce((app.settings()).vpage_stock_photos, true) then (
    select app.stock_photo_json(ph)
      from vehicle_stock_photos ph
      left join vehicle_catalog_popular pop on pop.make_slug = ph.make and pop.model_slug = ph.model
     where ph.kind = 'model' and ph.status = 'active' and ph.make = p_make
       and (p_model is null or ph.model = p_model)
       and (p_year is null or (ph.year_from <= p_year and ph.year_to >= p_year))
     order by (pop.sort is null), pop.sort, ph.year_to desc nulls last, ph.score desc nulls last
     limit 1) end
$$;

-- The generic photos of one kind of place or service page (rental, detailing, bodyshop, sale): the page shows one.
create or replace function public.stock_photos_generic(p_slot text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when coalesce((app.settings()).vpage_stock_photos, true) then coalesce((
    select jsonb_agg(app.stock_photo_json(ph) order by ph.score desc nulls last, ph.file_title)
      from vehicle_stock_photos ph where ph.kind = 'generic' and ph.slot = p_slot and ph.status = 'active'), '[]'::jsonb) else '[]'::jsonb end
$$;

-- ================================================================ 4. the pipeline (service role)
create or replace function app.stock_photo_run_begin(p jsonb) returns uuid
language sql security definer set search_path = public, app as $$
  insert into vehicle_stock_photo_runs (mode, run_url) values (coalesce(p ->> 'mode', 'write'), p ->> 'run_url') returning id
$$;
create or replace function app.stock_photo_run_finish(p jsonb) returns boolean
language sql security definer set search_path = public, app as $$
  update vehicle_stock_photo_runs set finished_at = now(), counts = p -> 'counts', errors = p -> 'errors' where id = (p ->> 'id')::uuid returning true
$$;

-- The models to look at, most wanted first: our fleet's models, the popular list in its order, then the newest and
-- longest-running. A model checked in the last p.refresh_days (180) is skipped; p.models (make/model) asks for those.
create or replace function app.stock_photo_targets(p jsonb default '{}'::jsonb) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with want as (select array(select jsonb_array_elements_text(coalesce(p -> 'models', '[]'::jsonb))) list),
  fleet as (select distinct cm.make_slug, cm.model_slug from vehicle_catalog_car_match cm join vehicles v on v.id = cm.vehicle_id
             where cm.model_slug is not null and not coalesce(v.is_sample, false)),
  models as (
    select m.make_slug make, m.slug model, mk.name make_name, m.name model_name, min(y.year)::int first_year, max(y.year)::int last_year, count(*)::int years,
           (f.make_slug is not null) in_fleet, pop.sort pop_sort
      from vehicle_catalog_models m
      join vehicle_catalog_makes mk on mk.slug = m.make_slug
      join vehicle_catalog_years y on y.make_slug = m.make_slug and y.model_slug = m.slug
      left join fleet f on f.make_slug = m.make_slug and f.model_slug = m.slug
      left join vehicle_catalog_popular pop on pop.make_slug = m.make_slug and pop.model_slug = m.slug
      left join vehicle_stock_photo_checks c on c.make = m.make_slug and c.model = m.slug
     where (cardinality((select w.list from want w)) > 0 and exists (select 1 from want w where (m.make_slug || '/' || m.slug) = any (w.list)))
        or (cardinality((select w.list from want w)) = 0 and (c.make is null or c.checked_at < now() - make_interval(days => coalesce((p ->> 'refresh_days')::int, 180))))
     group by m.make_slug, m.slug, mk.name, m.name, f.make_slug, pop.sort
     order by (f.make_slug is null), (pop.sort is null), pop.sort, max(y.year) desc, count(*) desc, m.make_slug, m.slug
     limit greatest(1, least(coalesce((p ->> 'limit')::int, 400), 5000)))
  select coalesce(jsonb_agg(to_jsonb(x) || jsonb_build_object('existing', coalesce((
      select jsonb_agg(jsonb_build_object('year_from', ph.year_from, 'file_title', ph.file_title, 'path', ph.path, 'status', ph.status, 'picked_by', ph.picked_by,
                                          'rejected_files', to_jsonb(ph.rejected_files)))
        from vehicle_stock_photos ph where ph.kind = 'model' and ph.make = x.make and ph.model = x.model), '[]'::jsonb))), '[]'::jsonb)
    from models x
$$;

-- Saves what the pipeline chose for one model (p: make, model, wikidata, note, run_id, rows[]): a new generation is
-- added, a changed file replaces the old (unless an Admin chose or hid it), a generation the pipeline no longer finds
-- is left as it is. Returns the stored files that are no longer used, for the pipeline to delete.
create or replace function app.stock_photo_save(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r jsonb;
  v_make text := p ->> 'make';
  v_model text := p ->> 'model';
  v_old jsonb := '[]'::jsonb;
  v_n integer := 0;
  e vehicle_stock_photos;
begin
  for r in select * from jsonb_array_elements(coalesce(p -> 'rows', '[]'::jsonb)) loop
    select * into e from vehicle_stock_photos where kind = 'model' and make = v_make and model = v_model and coalesce(year_from, 0) = coalesce((r ->> 'year_from')::int, 0);
    if found and (e.picked_by = 'admin' or e.status in ('hidden', 'pending')) then
      continue;
    end if;
    if coalesce((r ->> 'keep')::boolean, false) or r ->> 'path' is null then
      if found then update vehicle_stock_photos set checked_at = now() where id = e.id; v_n := v_n + 1; end if;
      continue;
    end if;
    if found then
      if e.path is not null and e.path <> r ->> 'path' then v_old := v_old || jsonb_build_array(jsonb_build_object('path', e.path, 'sizes', to_jsonb(e.sizes))); end if;
      update vehicle_stock_photos set year_to = (r ->> 'year_to')::smallint, generation = r ->> 'generation', wikidata = r ->> 'wikidata', category = r ->> 'category',
             file_title = r ->> 'file_title', source_url = r ->> 'source_url', author = r ->> 'author', author_url = r ->> 'author_url', licence = r ->> 'licence',
             licence_url = r ->> 'licence_url', path = r ->> 'path', sizes = array(select jsonb_array_elements_text(r -> 'sizes'))::smallint[],
             width = (r ->> 'width')::int, height = (r ->> 'height')::int, sha1 = r ->> 'sha1', score = (r ->> 'score')::numeric, status = 'active', note = null, checked_at = now()
       where id = e.id;
    else
      insert into vehicle_stock_photos (kind, make, model, year_from, year_to, generation, wikidata, category, file_title, source_url, author, author_url, licence, licence_url,
                                        path, sizes, width, height, sha1, score, status)
      values ('model', v_make, v_model, (r ->> 'year_from')::smallint, (r ->> 'year_to')::smallint, r ->> 'generation', r ->> 'wikidata', r ->> 'category', r ->> 'file_title',
              r ->> 'source_url', r ->> 'author', r ->> 'author_url', r ->> 'licence', r ->> 'licence_url', r ->> 'path',
              array(select jsonb_array_elements_text(r -> 'sizes'))::smallint[], (r ->> 'width')::int, (r ->> 'height')::int, r ->> 'sha1', (r ->> 'score')::numeric, 'active');
    end if;
    v_n := v_n + 1;
  end loop;
  insert into vehicle_stock_photo_checks (make, model, wikidata, photos, note, run_id, checked_at)
  values (v_make, v_model, p ->> 'wikidata', v_n, p ->> 'note', (p ->> 'run_id')::uuid, now())
  on conflict (make, model) do update set wikidata = excluded.wikidata, photos = excluded.photos, note = excluded.note, run_id = excluded.run_id, checked_at = now();
  return v_old;
end $$;

-- Saves a slot's generic photos (p: slot, rows[]): the new set replaces the pipeline's earlier one (hidden rows stay
-- hidden and are never chosen again). Returns the files no longer used.
create or replace function app.stock_photo_save_generic(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_slot text := p ->> 'slot';
  v_old jsonb;
  v_keep text[] := array(select x ->> 'file_title' from jsonb_array_elements(coalesce(p -> 'rows', '[]'::jsonb)) x);
begin
  if cardinality(v_keep) = 0 then return '[]'::jsonb; end if;
  select coalesce(jsonb_agg(jsonb_build_object('path', ph.path, 'sizes', to_jsonb(ph.sizes))) filter (where ph.path is not null), '[]'::jsonb) into v_old
    from vehicle_stock_photos ph where ph.kind = 'generic' and ph.slot = v_slot and ph.status = 'active' and ph.picked_by = 'pipeline' and not (ph.file_title = any (v_keep));
  delete from vehicle_stock_photos ph where ph.kind = 'generic' and ph.slot = v_slot and ph.status = 'active' and ph.picked_by = 'pipeline' and not (ph.file_title = any (v_keep));
  insert into vehicle_stock_photos (kind, slot, file_title, source_url, author, author_url, licence, licence_url, alt, path, sizes, width, height, sha1, score, status)
  select 'generic', v_slot, x ->> 'file_title', x ->> 'source_url', x ->> 'author', x ->> 'author_url', x ->> 'licence', x ->> 'licence_url', x ->> 'alt', x ->> 'path',
         array(select jsonb_array_elements_text(x -> 'sizes'))::smallint[], (x ->> 'width')::int, (x ->> 'height')::int, x ->> 'sha1', (x ->> 'score')::numeric, 'active'
    from jsonb_array_elements(p -> 'rows') x
  on conflict (slot, file_title) where kind = 'generic' do update set checked_at = now()
    where vehicle_stock_photos.status = 'active';
  return v_old;
end $$;

-- The Admin's requests (status pending): a named file, or pick again without the rejected files.
create or replace function app.stock_photo_pending() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', ph.id, 'make', ph.make, 'model', ph.model, 'make_name', mk.name, 'model_name', md.name, 'year_from', ph.year_from,
           'year_to', ph.year_to, 'generation', ph.generation, 'wikidata', ph.wikidata, 'category', ph.category, 'want_file', ph.want_file,
           'rejected_files', to_jsonb(ph.rejected_files)) order by ph.updated_at), '[]'::jsonb)
    from vehicle_stock_photos ph
    left join vehicle_catalog_makes mk on mk.slug = ph.make
    left join vehicle_catalog_models md on md.make_slug = ph.make and md.slug = ph.model
   where ph.kind = 'model' and ph.status = 'pending'
$$;

-- The result of a pending request (p: id, row or null, note): the new file becomes active (an Admin's choice when it
-- was named), or the request fails with the reason shown in Admin. Returns the old files to delete.
create or replace function app.stock_photo_resolve(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  e vehicle_stock_photos;
  r jsonb := p -> 'row';
begin
  select * into e from vehicle_stock_photos where id = (p ->> 'id')::uuid for update;
  if not found or e.status <> 'pending' then return '[]'::jsonb; end if;
  if r is null or jsonb_typeof(r) <> 'object' or r ->> 'path' is null then
    update vehicle_stock_photos set status = 'failed', note = coalesce(p ->> 'note', 'Not found'), checked_at = now() where id = e.id;
    return '[]'::jsonb;
  end if;
  update vehicle_stock_photos set file_title = r ->> 'file_title', source_url = r ->> 'source_url', author = r ->> 'author', author_url = r ->> 'author_url',
         licence = r ->> 'licence', licence_url = r ->> 'licence_url', path = r ->> 'path', sizes = array(select jsonb_array_elements_text(r -> 'sizes'))::smallint[],
         width = (r ->> 'width')::int, height = (r ->> 'height')::int, sha1 = r ->> 'sha1', score = (r ->> 'score')::numeric, status = 'active', want_file = null,
         picked_by = case when e.want_file is not null then 'admin' else 'pipeline' end, note = null, checked_at = now()
   where id = e.id;
  return case when e.path is not null and e.path <> r ->> 'path' then jsonb_build_array(jsonb_build_object('path', e.path, 'sizes', to_jsonb(e.sizes))) else '[]'::jsonb end;
end $$;

-- How far the photos reach: catalog models and model years with a photo, the popular models still without one.
create or replace function app.stock_photo_coverage() returns jsonb
language sql stable security definer set search_path = public, app as $$
  with ys as (
    select y.make_slug, y.model_slug, y.year,
           exists (select 1 from vehicle_stock_photos ph where ph.kind = 'model' and ph.status = 'active' and ph.make = y.make_slug and ph.model = y.model_slug
                      and y.year between ph.year_from and ph.year_to) has
      from vehicle_catalog_years y),
  ms as (
    select m.make_slug, m.slug, m.name, mk.name make_name, pop.sort,
           exists (select 1 from vehicle_stock_photos ph where ph.kind = 'model' and ph.status = 'active' and ph.make = m.make_slug and ph.model = m.slug) has,
           exists (select 1 from vehicle_stock_photo_checks c where c.make = m.make_slug and c.model = m.slug) checked
      from vehicle_catalog_models m join vehicle_catalog_makes mk on mk.slug = m.make_slug
      left join vehicle_catalog_popular pop on pop.make_slug = m.make_slug and pop.model_slug = m.slug)
  select jsonb_build_object(
    'models', (select count(*) from ms), 'models_checked', (select count(*) from ms where checked), 'models_with_photo', (select count(*) from ms where has),
    'model_years', (select count(*) from ys), 'model_years_with_photo', (select count(*) from ys where has),
    'generations', (select count(*) from vehicle_stock_photos where kind = 'model' and status = 'active' and year_from is not null),
    'model_only', (select count(*) from vehicle_stock_photos where kind = 'model' and status = 'active' and year_from is null),
    'hidden', (select count(*) from vehicle_stock_photos where status = 'hidden'), 'pending', (select count(*) from vehicle_stock_photos where status = 'pending'),
    'failed', (select count(*) from vehicle_stock_photos where status = 'failed'),
    'generic', (select coalesce(jsonb_object_agg(slot, n), '{}'::jsonb) from (select slot, count(*) n from vehicle_stock_photos where kind = 'generic' and status = 'active' group by slot) g),
    'popular', (select count(*) from ms where sort is not null), 'popular_with_photo', (select count(*) from ms where sort is not null and has),
    'popular_missing', coalesce((select jsonb_agg(make_name || ' ' || name order by sort) from ms where sort is not null and not has), '[]'::jsonb),
    'last_run', (select to_jsonb(r) from vehicle_stock_photo_runs r order by started_at desc limit 1))
$$;

-- ================================================================ 5. Admin
create or replace function app.stock_photo_admin_list() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('coverage', app.stock_photo_coverage(),
    'photos', coalesce((select jsonb_agg(app.stock_photo_json(ph) || jsonb_build_object('kind', ph.kind, 'status', ph.status, 'file_title', ph.file_title, 'note', ph.note,
                 'picked_by', ph.picked_by, 'want_file', ph.want_file, 'checked_at', ph.checked_at)
               order by ph.kind desc, ph.make, ph.model, ph.year_from nulls first, ph.slot, ph.file_title) from vehicle_stock_photos ph), '[]'::jsonb))
$$;

-- p: id, op (hide, show, replace with file, repick). Hide and pick again add the file to the rejected files.
create or replace function app.stock_photo_admin(p_admin uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  e vehicle_stock_photos;
  v_op text := p ->> 'op';
  v_file text := nullif(btrim(coalesce(p ->> 'file', '')), '');
begin
  perform app.assert_admin(p_admin);
  perform set_config('request.jwt.claim.sub', p_admin::text, true);
  select * into e from vehicle_stock_photos where id::text = p ->> 'id' for update;
  if not found then raise exception 'That photo is not there any more' using errcode = 'P0002'; end if;
  if v_op = 'hide' then
    update vehicle_stock_photos set status = 'hidden', rejected_files = array(select distinct x from unnest(rejected_files || e.file_title) x), updated_by = p_admin where id = e.id;
  elsif v_op = 'show' then
    if e.path is null then raise exception 'This photo was never stored: use Pick again or Replace' using errcode = '22023'; end if;
    update vehicle_stock_photos set status = 'active', rejected_files = array_remove(rejected_files, e.file_title), updated_by = p_admin, note = null where id = e.id;
  elsif v_op = 'replace' then
    if e.kind <> 'model' then raise exception 'Generic photos are replaced by hiding them: the next run picks another' using errcode = '22023'; end if;
    if v_file is null or v_file !~* '^(https://commons\.wikimedia\.org/wiki/File:[^[:space:]/|#<>{}\[\]]+|(File:)?[^/:|#<>{}\[\]]+)\.(jpe?g|png|webp)$' then
      raise exception 'Give a Wikimedia Commons file: its address (https://commons.wikimedia.org/wiki/File:...) or its name (File:....jpg)' using errcode = '22023';
    end if;
    update vehicle_stock_photos set status = 'pending', want_file = v_file, rejected_files = array(select distinct x from unnest(rejected_files || e.file_title) x),
           updated_by = p_admin, note = null where id = e.id;
  elsif v_op = 'repick' then
    if e.kind <> 'model' then raise exception 'Generic photos are replaced by hiding them: the next run picks another' using errcode = '22023'; end if;
    update vehicle_stock_photos set status = 'pending', want_file = null, rejected_files = array(select distinct x from unnest(rejected_files || e.file_title) x),
           updated_by = p_admin, note = null where id = e.id;
  else
    raise exception 'Unknown change: %', v_op using errcode = '22023';
  end if;
  return (select app.stock_photo_json(ph) || jsonb_build_object('status', ph.status) from vehicle_stock_photos ph where ph.id = e.id);
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0137;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'admin_read' and p_name = 'stock_photos' then
    perform app.door_begin(p_user, p_aal);
    perform app.assert_admin(p_user);
    return app.stock_photo_admin_list();
  end if;
  if p_call = 'admin_do' and p_name = 'stock_photo' then
    perform app.door_begin(p_user, p_aal);
    return app.stock_photo_admin(p_user, coalesce(p, '{}'::jsonb));
  end if;
  return app.door_pre0137(p_user, p_aal, p_call, p_name, p);
end $$;

-- ================================================================ privileges
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['door', 'door_pre0137', 'stock_photo_json', 'stock_photo_run_begin', 'stock_photo_run_finish', 'stock_photo_targets',
       'stock_photo_save', 'stock_photo_save_generic', 'stock_photo_pending', 'stock_photo_resolve', 'stock_photo_coverage', 'stock_photo_admin_list', 'stock_photo_admin'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
revoke all on function public.vehicle_stock_photo(text, text, integer), public.stock_photos_generic(text) from public;
grant execute on function public.vehicle_stock_photo(text, text, integer), public.stock_photos_generic(text) to anon, authenticated, service_role;

-- ================================================================ 6. the guides
-- GUIDES 0137 START (generated by supabase/seed/0137_gen_guides.mjs from docs/guides/content; do not edit by hand)
-- GUIDES 0137 END
