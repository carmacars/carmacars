-- 0137_seo_photos.sql
-- Licensed stock photos for the vehicle pages (docs/changes/2026-10-24-seo-photos.md). The owner, October 24, 2026:
-- the programmatic pages of every make, model, year and trim (and the place and service pages) mostly have no photo;
-- use properly licensed images, never scraped copyrighted photos.
--
-- 1. vehicle_stock_photos: one photo per make, model and generation (model years year_from to year_to; none for a
--    photo of the model in general), and a few generic photos per kind of place and service page (slot). Each with its
--    file (Wikimedia Commons, or Openverse when Commons has none, its licence confirmed at the source page), author,
--    licence (public domain, CC0, CC BY or CC BY-SA only: a check) and source, the
--    stored WebP widths in the public bucket (vehicle-public, seo-photos/...), and a status (active, hidden by an
--    Admin, pending a replacement, failed). Never a fleet car's photo: the fleet's photos stay in vehicle_photos.
-- 2. vehicle_stock_photo_checks (each model the pipeline has looked at: resumable runs and the coverage report) and
--    vehicle_stock_photo_runs (each run of .github/workflows/seo-photos.yml).
-- 3. The pages' reads: public.vehicle_stock_photo(make, model, year): the generation of that model year (match
--    exact); else the next generation a model year off (near); else any photo of the model (model, labelled on the
--    page "not the exact year"); a model page, the newest generation; a make page, its most popular model's. And
--    public.stock_photos_generic(slot).
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
  file_title    text not null check (btrim(file_title) <> ''),
  source_url    text not null check (source_url ~ '^https://[^[:space:]]+$'),
  source_name   text not null default 'Wikimedia Commons' check (btrim(source_name) <> ''),
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
comment on column vehicle_stock_photos.source_name is 'Where the photo is from, as the credit names it: Wikimedia Commons, or "<site> via Openverse" (its licence confirmed at source_url)';
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
    'source_url', ph.source_url, 'source_name', ph.source_name, 'alt', ph.alt)
$$;

-- The photo for a vehicle page, best fit first: the generation of that model year (match exact); the next generation
-- when the year is a model year off its range (near: a model year a generation's dates miss by one); any photo of the
-- model (model: the page says "Representative photo of the <model>, not the exact year"; the owner prefers a real
-- photo to the drawing). A model page gets the newest generation, a make page its most popular model's. Null when there
-- is none (the studio drawing) or the setting is off.
create or replace function public.vehicle_stock_photo(p_make text, p_model text default null, p_year integer default null) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when coalesce((app.settings()).vpage_stock_photos, true) then (
    select app.stock_photo_json(x.ph) || jsonb_build_object('match', case when p_year is null or p_model is null then 'exact' when x.rank = 0 then 'exact' when x.rank = 1 then 'near' else 'model' end)
      from (select ph,
                   case when p_year is null or p_model is null then 0
                        when ph.year_from <= p_year and ph.year_to >= p_year then 0
                        when ph.year_from - 1 <= p_year and ph.year_to + 1 >= p_year then 1
                        else 2 end as rank,
                   case when p_year is null or ph.year_from is null then 0 else least(abs(p_year - ph.year_from), abs(p_year - ph.year_to)) end as dist,
                   pop.sort
              from vehicle_stock_photos ph
              left join vehicle_catalog_popular pop on pop.make_slug = ph.make and pop.model_slug = ph.model
             where ph.kind = 'model' and ph.status = 'active' and ph.make = p_make and (p_model is null or ph.model = p_model)) x
     order by x.rank, (x.sort is null), x.sort, case when p_year is null then 0 else x.dist end, (x.ph).year_to desc nulls last, (x.ph).score desc nulls last
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
             file_title = r ->> 'file_title', source_url = r ->> 'source_url', source_name = coalesce(r ->> 'source_name', 'Wikimedia Commons'),
             author = r ->> 'author', author_url = r ->> 'author_url', licence = r ->> 'licence',
             licence_url = r ->> 'licence_url', path = r ->> 'path', sizes = array(select jsonb_array_elements_text(r -> 'sizes'))::smallint[],
             width = (r ->> 'width')::int, height = (r ->> 'height')::int, sha1 = r ->> 'sha1', score = (r ->> 'score')::numeric, status = 'active', note = null, checked_at = now()
       where id = e.id;
    else
      insert into vehicle_stock_photos (kind, make, model, year_from, year_to, generation, wikidata, category, file_title, source_url, source_name, author, author_url, licence, licence_url,
                                        path, sizes, width, height, sha1, score, status)
      values ('model', v_make, v_model, (r ->> 'year_from')::smallint, (r ->> 'year_to')::smallint, r ->> 'generation', r ->> 'wikidata', r ->> 'category', r ->> 'file_title',
              r ->> 'source_url', coalesce(r ->> 'source_name', 'Wikimedia Commons'), r ->> 'author', r ->> 'author_url', r ->> 'licence', r ->> 'licence_url', r ->> 'path',
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
  insert into vehicle_stock_photos (kind, slot, file_title, source_url, source_name, author, author_url, licence, licence_url, alt, path, sizes, width, height, sha1, score, status)
  select 'generic', v_slot, x ->> 'file_title', x ->> 'source_url', coalesce(x ->> 'source_name', 'Wikimedia Commons'), x ->> 'author', x ->> 'author_url', x ->> 'licence', x ->> 'licence_url', x ->> 'alt', x ->> 'path',
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
  update vehicle_stock_photos set file_title = r ->> 'file_title', source_url = r ->> 'source_url', source_name = coalesce(r ->> 'source_name', 'Wikimedia Commons'),
         author = r ->> 'author', author_url = r ->> 'author_url',
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
                      and y.year between ph.year_from and ph.year_to) has,
           exists (select 1 from vehicle_stock_photos ph where ph.kind = 'model' and ph.status = 'active' and ph.make = y.make_slug and ph.model = y.model_slug
                      and y.year between ph.year_from - 1 and ph.year_to + 1) near,
           exists (select 1 from vehicle_stock_photos ph where ph.kind = 'model' and ph.status = 'active' and ph.make = y.make_slug and ph.model = y.model_slug) any_photo
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
    'model_years_near', (select count(*) from ys where near and not has), 'model_years_model_only', (select count(*) from ys where any_photo and not near),
    'generations', (select count(*) from vehicle_stock_photos where kind = 'model' and status = 'active' and year_from is not null),
    'model_only', (select count(*) from vehicle_stock_photos where kind = 'model' and status = 'active' and year_from is null),
    'hidden', (select count(*) from vehicle_stock_photos where status = 'hidden'), 'pending', (select count(*) from vehicle_stock_photos where status = 'pending'),
    'failed', (select count(*) from vehicle_stock_photos where status = 'failed'),
    'generic', (select coalesce(jsonb_object_agg(slot, n), '{}'::jsonb) from (select slot, count(*) n from vehicle_stock_photos where kind = 'generic' and status = 'active' group by slot) g),
    'popular', (select count(*) from ms where sort is not null), 'popular_with_photo', (select count(*) from ms where sort is not null and has),
    'popular_with_generation', (select count(*) from ms where sort is not null and exists (select 1 from vehicle_stock_photos ph where ph.kind = 'model' and ph.status = 'active'
                                  and ph.make = ms.make_slug and ph.model = ms.slug and ph.year_from is not null)),
    'sources', (select coalesce(jsonb_object_agg(source_name, n), '{}'::jsonb) from (select source_name, count(*) n from vehicle_stock_photos where status = 'active' group by source_name) z),
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
select app.guide_release_section('admin', 'search-car-pages-landing-pages-and-guides', 'chapter', 'discount-games-and-leads', 'The text of every car page, the landing pages for each area and way of renting, and the guides are written by Workers AI from the facts in the database, checked and published by themselves. Nobody has to type or review anything. You can still change any line; what you change is kept.

## The copy of a car

**Cars** > **Vehicles**, then the car, then its Listing tab. The same card is on the listing review.

1. The card says who wrote the text: a plain copy from the car''s facts while the written copy is prepared (usually minutes), then Workers AI.
2. Every field is shown: search title and description, heading, introduction, highlights, good for, what''s included, pickup and delivery, requirements, questions and the photo descriptions.
3. To change a field press **Change**, then **Save and lock**. A locked field is kept by every new version. **Unlock** lets it be written again.
4. **Write again** asks for a new version now. A new version is also written by itself when the car''s facts change: its rates, specs, area or photos.

> Good to know: The checks refuse long dashes, sales words, the numbered company, any number that is not in the car''s facts (a price, a seat count) and equipment the facts do not list. A version that fails is asked again with the problems named; if it still fails, the page keeps its current text and it is tried again later.

## Landing pages and guides

**Settings** > **All settings**, then Search.

1. Today: the Workers AI used for search copy and in all, and IndexNow (addresses waiting and sent).
2. Car copy: every real car, who wrote its text, and whether its facts changed since.
3. Landing pages: each place and way of renting, whether it is in search, its cars and who wrote it. A page for a way of renting (monthly, SUV) goes into search once enough real cars match it (Program settings).
4. Open **Edit** on a page or a guide to change its text. Edited fields are locked. **Write again** asks for a new version; on a guide, the brief says what it must cover.

## Vehicle pages

**Settings** > **Vehicle pages**. A page for every make, model, model year and Canadian trim of every year, at carmacars.ca/cars/make/model/year/trim, with our cars below it; each trim also in every place and in 12 colours (a black 2020 Volkswagen Jetta Sportline in Mississauga, for example); every page again for sale (carmacars.ca/buy/...) and for each search term: renting (car hire), sale (financing), detailing (ceramic coating) and body shop (bumper repair), at carmacars.ca/t/term/...

1. Pages: how many pages each level and each tier has, the total, and how many are in search. Every page is in search by default; nothing needs setting up.
2. One switch per tier takes it out of search at once: **Index the place pages**, **Index the colour pages**, **Index the search term pages**, **Index the /buy pages**, **Index the detailing pages**, **Index the body shop pages**. Off, those pages stay visible but leave the sitemaps and search.
3. The places are the place list of the local search release (every city, town and neighbourhood, with GTA and country levels); until it is filled, the area landing pages. The search terms are edited with them.
4. **Financing disclaimer**: the text on financing and leasing pages. CarmaCars never says it lends or leases.
5. Database: its size against the cap the catalog and places imports keep under: the cap of the Database plan (Pro, 6,144 MB, by default; Free, 450 MB). IndexNow: the addresses sent today, where the sweep is, and any back-off; nothing to do.
6. Each page is built from data: the EPA fuel-use ratings in litres per 100 km, the cost to drive 100 km at the gas or electricity price set here, what changed from the year before, how a trim differs from the others, similar models, and the rental questions from the program settings.
7. Below the facts: our cars of that exact year, model and trim, then the same model in other years, then similar cars free now, and Request it, which sends an enquiry to Bookings > Leads.
8. Settings: **Index every page** (the default) or **Only pages that pass the rules**: makes, models with 2 or more years of data, years with one of our cars or of a popular model from 2015, trims with one of our cars. The others stay visible but out of search. Also the gas, premium and electricity prices, and how often the catalog is imported (every 30 days).
9. Canadian trims: open a model and type one line per run of years, entry trim first: 2020-2021: Comfortline, Highline, Sportline, Execline. Your lines are kept by every import; empty them to go back to the CarmaCars list. **Add trims for another model** adds a model that has none.
10. Catalog import: the last import and its counts. **Import now** asks for a new one; it runs at the next daily check, at 07:17 UTC.

> Good to know: A car joins its pages by itself once it is on the site: its make, model, year and trim are read from the car. A trim that names several (S / SE / R-Line) leaves the car on the year page only; set the car''s trim to one Canadian name to put it on the trim page.

## A car for sale

**Cars** > **Vehicles**, then the car. On the For sale card, tick **For sale**, enter the Asking price and press **Save**.

1. The car then shows at the top of its /buy pages (its make, model, year and trim) with the asking price, the only time a page says a car is for sale.
2. Untick it when the car is sold or no longer for sale: the pages say so at once.
3. "Find me this car" on the /buy pages sends a buyer lead to Sales (staff portal: **Owner leads**, Buyer leads), with a To do line.

## Search engines and business listings

**Settings** > **All settings**, then Site settings.

1. Search engines: paste the Google Search Console value (HTML tag) or the file name (HTML file), and the Bing value. The steps are on the card.
2. Business name, address and phone: the exact text for every listing, and the description and categories.
3. Business listings: press **Copy** beside each line and paste it into Google Business Profile, Bing Places, Apple Business Connect, Yelp, Yellow Pages and Facebook. Tick each one when it is done.

> Good to know: Changed pages are sent to IndexNow (Bing and the other engines that use it) by themselves. Google reads the sitemap: submit carmacars.ca/sitemap.xml once in Search Console.

## Place pages

Every place we have, from a country down to a neighbourhood, gets a page for every term people search with: renting (car hire, SUV rental, monthly car rental ...), buying help (used cars, car financing ...), detailing (ceramic coating, window tint ...) and body work (collision repair, dent repair ...). Each page is written from real data only: the distance from us, the delivery price within our reach, the nearest airport, the landmarks near it, our live cars and the places around it. A place far from Toronto says we serve the Toronto area and takes a request instead. **Settings** > **All settings**, then Search.

1. Place pages: four switches, one for each family, put the pages in search and in the sitemaps. All four are on.
2. Quality gate: off. On, only places within the delivery reach are in search, and rental pages only with a real matching car. Search engines can treat many similar pages as low value; the gate lowers that risk.
3. Delivery reach: places within this distance of our location are offered delivery. Database size cap: the places import stops before the database passes it.
4. Regions and places: every province, state and territory is on. Untick a region to take its pages and sitemaps off the site.
5. Terms and services: change a term''s title or what is true about it, point a synonym to another term (its pages then leave search), switch a term off, or add one. Give a service a starting price, or leave it empty for "price on request".

> Good to know: A region has pages once the places workflow has loaded it: GitHub, Actions, places, Run workflow, with the regions or all. The run loads Ontario first and names any region it skipped because of the size cap.

## Requests from the place pages

The buying help, detailing and body shop pages, and the pages of places beyond our reach, have a request form. Each request is a lead with a task in **To do**: detailing and body shop requests are due within an hour of opening and show in Today. Buying help pages say plainly that CarmaCars does not sell, finance or lease cars; the notice at the top is set under Place pages.

Mechanical work has pages too, under the body shop pages and listed apart as "Auto services we arrange": a mechanic, oil changes, brakes, tires and winter tires, towing, batteries and boosts, alignment, transmission and engine repair, diagnostics, inspections and the Ontario safety certificate, emissions, AC, exhaust and suspension. CarmaCars does not do this work, and the pages say so: each takes a request (a "Mechanical work to arrange" task, due within an hour of opening) and offers a rental while the car is in. They have no questions of their own; their per car pages (for each make, model, year and trim) say the same and take the same request.

## One name, address and phone

The footer, the contact page, the structured data and every business listing show the business address of Site settings. Keep it the address renters come to, and change it there only.
', 'Search: car pages, landing pages and guides', 'Car copy written by itself, landing pages, place pages for every place and term, detailing and body shop, guides, business listings and IndexNow.',
  'The text of every car page, the landing pages for each area and way of renting, and the guides are written by Workers AI from the facts in the database, checked and published by themselves. Nobody has to type or review anything. You can still change any line; what you change is kept.

## The copy of a car

**Cars** > **Vehicles**, then the car, then its Listing tab. The same card is on the listing review.

1. The card says who wrote the text: a plain copy from the car''s facts while the written copy is prepared (usually minutes), then Workers AI.
2. Every field is shown: search title and description, heading, introduction, highlights, good for, what''s included, pickup and delivery, requirements, questions and the photo descriptions.
3. To change a field press **Change**, then **Save and lock**. A locked field is kept by every new version. **Unlock** lets it be written again.
4. **Write again** asks for a new version now. A new version is also written by itself when the car''s facts change: its rates, specs, area or photos.

> Good to know: The checks refuse long dashes, sales words, the numbered company, any number that is not in the car''s facts (a price, a seat count) and equipment the facts do not list. A version that fails is asked again with the problems named; if it still fails, the page keeps its current text and it is tried again later.

## Landing pages and guides

**Settings** > **All settings**, then Search.

1. Today: the Workers AI used for search copy and in all, and IndexNow (addresses waiting and sent).
2. Car copy: every real car, who wrote its text, and whether its facts changed since.
3. Landing pages: each place and way of renting, whether it is in search, its cars and who wrote it. A page for a way of renting (monthly, SUV) goes into search once enough real cars match it (Program settings).
4. Open **Edit** on a page or a guide to change its text. Edited fields are locked. **Write again** asks for a new version; on a guide, the brief says what it must cover.

## Vehicle pages

**Settings** > **Vehicle pages**. A page for every make, model, model year and Canadian trim of every year, at carmacars.ca/cars/make/model/year/trim, with our cars below it; each trim also in every place and in 12 colours (a black 2020 Volkswagen Jetta Sportline in Mississauga, for example); every page again for sale (carmacars.ca/buy/...) and for each search term: renting (car hire), sale (financing), detailing (ceramic coating) and body shop (bumper repair), at carmacars.ca/t/term/...

1. Pages: how many pages each level and each tier has, the total, and how many are in search. Every page is in search by default; nothing needs setting up.
2. One switch per tier takes it out of search at once: **Index the place pages**, **Index the colour pages**, **Index the search term pages**, **Index the /buy pages**, **Index the detailing pages**, **Index the body shop pages**. Off, those pages stay visible but leave the sitemaps and search.
3. The places are the place list of the local search release (every city, town and neighbourhood, with GTA and country levels); until it is filled, the area landing pages. The search terms are edited with them.
4. **Financing disclaimer**: the text on financing and leasing pages. CarmaCars never says it lends or leases.
5. Database: its size against the cap the catalog and places imports keep under: the cap of the Database plan (Pro, 6,144 MB, by default; Free, 450 MB). IndexNow: the addresses sent today, where the sweep is, and any back-off; nothing to do.
6. Each page is built from data: the EPA fuel-use ratings in litres per 100 km, the cost to drive 100 km at the gas or electricity price set here, what changed from the year before, how a trim differs from the others, similar models, and the rental questions from the program settings.
7. Below the facts: our cars of that exact year, model and trim, then the same model in other years, then similar cars free now, and Request it, which sends an enquiry to Bookings > Leads.
8. Settings: **Index every page** (the default) or **Only pages that pass the rules**: makes, models with 2 or more years of data, years with one of our cars or of a popular model from 2015, trims with one of our cars. The others stay visible but out of search. Also the gas, premium and electricity prices, and how often the catalog is imported (every 30 days).
9. Canadian trims: open a model and type one line per run of years, entry trim first: 2020-2021: Comfortline, Highline, Sportline, Execline. Your lines are kept by every import; empty them to go back to the CarmaCars list. **Add trims for another model** adds a model that has none.
10. Catalog import: the last import and its counts. **Import now** asks for a new one; it runs at the next daily check, at 07:17 UTC.

> Good to know: A car joins its pages by itself once it is on the site: its make, model, year and trim are read from the car. A trim that names several (S / SE / R-Line) leaves the car on the year page only; set the car''s trim to one Canadian name to put it on the trim page.

## Stock photos on the vehicle pages

**Settings** > **Vehicle pages**, card Stock photos. The vehicle pages show a real photo of the make, model and generation at the top (a 2015 Camry page shows a Camry of the 2012 to 2017 generation), with the credit always under it: "Photo: author, licence, Wikimedia Commons". The place pages and the detailing and body shop pages show a photo of a road, a car being detailed or a body shop. Our own cars always show their own photos.

1. Nothing to set up: the photos come by themselves every day, our fleet''s models and the popular models first. Only free licences are used (public domain, CC0, CC BY, CC BY-SA), from Wikimedia Commons. A year no generation covers keeps the studio drawing.
2. The card shows how many models and model years have a photo, the popular models still without one, and the last run.
3. Open a make to see its photos. A wrong car, a poor photo or a photo you do not want: press **Hide**. The page goes back to the studio drawing at once, and that photo is never picked again.
4. **Pick again** asks for the next best photo; **Replace** takes a photo you found on Wikimedia Commons: paste its address (https://commons.wikimedia.org/wiki/File:...). Either is done at the next daily run, after its licence is checked. A photo whose licence is not allowed is refused, with the reason.
5. **Show stock photos** in the settings above turns every stock photo off at once (on by default).

> Good to know: Never upload or use a photo from Google, a dealer or a manufacturer''s site here: only Wikimedia Commons files, with the credit the page shows.

## A car for sale

**Cars** > **Vehicles**, then the car. On the For sale card, tick **For sale**, enter the Asking price and press **Save**.

1. The car then shows at the top of its /buy pages (its make, model, year and trim) with the asking price, the only time a page says a car is for sale.
2. Untick it when the car is sold or no longer for sale: the pages say so at once.
3. "Find me this car" on the /buy pages sends a buyer lead to Sales (staff portal: **Owner leads**, Buyer leads), with a To do line.

## Search engines and business listings

**Settings** > **All settings**, then Site settings.

1. Search engines: paste the Google Search Console value (HTML tag) or the file name (HTML file), and the Bing value. The steps are on the card.
2. Business name, address and phone: the exact text for every listing, and the description and categories.
3. Business listings: press **Copy** beside each line and paste it into Google Business Profile, Bing Places, Apple Business Connect, Yelp, Yellow Pages and Facebook. Tick each one when it is done.

> Good to know: Changed pages are sent to IndexNow (Bing and the other engines that use it) by themselves. Google reads the sitemap: submit carmacars.ca/sitemap.xml once in Search Console.

## Place pages

Every place we have, from a country down to a neighbourhood, gets a page for every term people search with: renting (car hire, SUV rental, monthly car rental ...), buying help (used cars, car financing ...), detailing (ceramic coating, window tint ...) and body work (collision repair, dent repair ...). Each page is written from real data only: the distance from us, the delivery price within our reach, the nearest airport, the landmarks near it, our live cars and the places around it. A place far from Toronto says we serve the Toronto area and takes a request instead. **Settings** > **All settings**, then Search.

1. Place pages: four switches, one for each family, put the pages in search and in the sitemaps. All four are on.
2. Quality gate: off. On, only places within the delivery reach are in search, and rental pages only with a real matching car. Search engines can treat many similar pages as low value; the gate lowers that risk.
3. Delivery reach: places within this distance of our location are offered delivery. Database size cap: the places import stops before the database passes it.
4. Regions and places: every province, state and territory is on. Untick a region to take its pages and sitemaps off the site.
5. Terms and services: change a term''s title or what is true about it, point a synonym to another term (its pages then leave search), switch a term off, or add one. Give a service a starting price, or leave it empty for "price on request".

> Good to know: A region has pages once the places workflow has loaded it: GitHub, Actions, places, Run workflow, with the regions or all. The run loads Ontario first and names any region it skipped because of the size cap.

## Requests from the place pages

The buying help, detailing and body shop pages, and the pages of places beyond our reach, have a request form. Each request is a lead with a task in **To do**: detailing and body shop requests are due within an hour of opening and show in Today. Buying help pages say plainly that CarmaCars does not sell, finance or lease cars; the notice at the top is set under Place pages.

Mechanical work has pages too, under the body shop pages and listed apart as "Auto services we arrange": a mechanic, oil changes, brakes, tires and winter tires, towing, batteries and boosts, alignment, transmission and engine repair, diagnostics, inspections and the Ontario safety certificate, emissions, AC, exhaust and suspension. CarmaCars does not do this work, and the pages say so: each takes a request (a "Mechanical work to arrange" task, due within an hour of opening) and offers a rental while the car is in. They have no questions of their own; their per car pages (for each make, model, year and trim) say the same and take the same request.

## One name, address and phone

The footer, the contact page, the structured data and every business listing show the business address of Site settings. Keep it the address renters come to, and change it there only.
',
  '<p class="gd-p">The text of every car page, the landing pages for each area and way of renting, and the guides are written by Workers AI from the facts in the database, checked and published by themselves. Nobody has to type or review anything. You can still change any line; what you change is kept.</p><section class="gd-task" id="search-car-pages-landing-pages-and-guides-the-copy-of-a-car" data-gd-task><h2 class="gd-h2">The copy of a car</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Vehicles</b>, then the car, then its Listing tab. The same card is on the listing review.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The card says who wrote the text: a plain copy from the car&#39;s facts while the written copy is prepared (usually minutes), then Workers AI.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Every field is shown: search title and description, heading, introduction, highlights, good for, what&#39;s included, pickup and delivery, requirements, questions and the photo descriptions.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">To change a field press <b class="gd-ui">Change</b>, then <b class="gd-ui">Save and lock</b>. A locked field is kept by every new version. <b class="gd-ui">Unlock</b> lets it be written again.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Write again</b> asks for a new version now. A new version is also written by itself when the car&#39;s facts change: its rates, specs, area or photos.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>The checks refuse long dashes, sales words, the numbered company, any number that is not in the car&#39;s facts (a price, a seat count) and equipment the facts do not list. A version that fails is asked again with the problems named; if it still fails, the page keeps its current text and it is tried again later.</div></aside></section><section class="gd-task" id="search-car-pages-landing-pages-and-guides-landing-pages-and-guides" data-gd-task><h2 class="gd-h2">Landing pages and guides</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">All settings</b>, then Search.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Today: the Workers AI used for search copy and in all, and IndexNow (addresses waiting and sent).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Car copy: every real car, who wrote its text, and whether its facts changed since.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Landing pages: each place and way of renting, whether it is in search, its cars and who wrote it. A page for a way of renting (monthly, SUV) goes into search once enough real cars match it (Program settings).</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Open <b class="gd-ui">Edit</b> on a page or a guide to change its text. Edited fields are locked. <b class="gd-ui">Write again</b> asks for a new version; on a guide, the brief says what it must cover.</div></li></ol></div></section><section class="gd-task" id="search-car-pages-landing-pages-and-guides-vehicle-pages" data-gd-task><h2 class="gd-h2">Vehicle pages</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Vehicle pages</b>. A page for every make, model, model year and Canadian trim of every year, at carmacars.ca/cars/make/model/year/trim, with our cars below it; each trim also in every place and in 12 colours (a black 2020 Volkswagen Jetta Sportline in Mississauga, for example); every page again for sale (carmacars.ca/buy/...) and for each search term: renting (car hire), sale (financing), detailing (ceramic coating) and body shop (bumper repair), at carmacars.ca/t/term/...</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Pages: how many pages each level and each tier has, the total, and how many are in search. Every page is in search by default; nothing needs setting up.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">One switch per tier takes it out of search at once: <b class="gd-ui">Index the place pages</b>, <b class="gd-ui">Index the colour pages</b>, <b class="gd-ui">Index the search term pages</b>, <b class="gd-ui">Index the /buy pages</b>, <b class="gd-ui">Index the detailing pages</b>, <b class="gd-ui">Index the body shop pages</b>. Off, those pages stay visible but leave the sitemaps and search.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The places are the place list of the local search release (every city, town and neighbourhood, with GTA and country levels); until it is filled, the area landing pages. The search terms are edited with them.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Financing disclaimer</b>: the text on financing and leasing pages. CarmaCars never says it lends or leases.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Database: its size against the cap the catalog and places imports keep under: the cap of the Database plan (Pro, 6,144 MB, by default; Free, 450 MB). IndexNow: the addresses sent today, where the sweep is, and any back-off; nothing to do.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Each page is built from data: the EPA fuel-use ratings in litres per 100 km, the cost to drive 100 km at the gas or electricity price set here, what changed from the year before, how a trim differs from the others, similar models, and the rental questions from the program settings.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Below the facts: our cars of that exact year, model and trim, then the same model in other years, then similar cars free now, and Request it, which sends an enquiry to Bookings &gt; Leads.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Settings: <b class="gd-ui">Index every page</b> (the default) or <b class="gd-ui">Only pages that pass the rules</b>: makes, models with 2 or more years of data, years with one of our cars or of a popular model from 2015, trims with one of our cars. The others stay visible but out of search. Also the gas, premium and electricity prices, and how often the catalog is imported (every 30 days).</div></li><li><span class="gd-n" aria-hidden="true">9</span><div class="gd-t">Canadian trims: open a model and type one line per run of years, entry trim first: 2020-2021: Comfortline, Highline, Sportline, Execline. Your lines are kept by every import; empty them to go back to the CarmaCars list. <b class="gd-ui">Add trims for another model</b> adds a model that has none.</div></li><li><span class="gd-n" aria-hidden="true">10</span><div class="gd-t">Catalog import: the last import and its counts. <b class="gd-ui">Import now</b> asks for a new one; it runs at the next daily check, at 07:17 UTC.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A car joins its pages by itself once it is on the site: its make, model, year and trim are read from the car. A trim that names several (S / SE / R-Line) leaves the car on the year page only; set the car&#39;s trim to one Canadian name to put it on the trim page.</div></aside></section><section class="gd-task" id="search-car-pages-landing-pages-and-guides-stock-photos-on-the-vehicle-pages" data-gd-task><h2 class="gd-h2">Stock photos on the vehicle pages</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Vehicle pages</b>, card Stock photos. The vehicle pages show a real photo of the make, model and generation at the top (a 2015 Camry page shows a Camry of the 2012 to 2017 generation), with the credit always under it: &quot;Photo: author, licence, Wikimedia Commons&quot;. The place pages and the detailing and body shop pages show a photo of a road, a car being detailed or a body shop. Our own cars always show their own photos.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Nothing to set up: the photos come by themselves every day, our fleet&#39;s models and the popular models first. Only free licences are used (public domain, CC0, CC BY, CC BY-SA), from Wikimedia Commons. A year no generation covers keeps the studio drawing.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The card shows how many models and model years have a photo, the popular models still without one, and the last run.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Open a make to see its photos. A wrong car, a poor photo or a photo you do not want: press <b class="gd-ui">Hide</b>. The page goes back to the studio drawing at once, and that photo is never picked again.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Pick again</b> asks for the next best photo; <b class="gd-ui">Replace</b> takes a photo you found on Wikimedia Commons: paste its address (https://commons.wikimedia.org/wiki/File:...). Either is done at the next daily run, after its licence is checked. A photo whose licence is not allowed is refused, with the reason.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><b class="gd-ui">Show stock photos</b> in the settings above turns every stock photo off at once (on by default).</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Never upload or use a photo from Google, a dealer or a manufacturer&#39;s site here: only Wikimedia Commons files, with the credit the page shows.</div></aside></section><section class="gd-task" id="search-car-pages-landing-pages-and-guides-a-car-for-sale" data-gd-task><h2 class="gd-h2">A car for sale</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Vehicles</b>, then the car. On the For sale card, tick <b class="gd-ui">For sale</b>, enter the Asking price and press <b class="gd-ui">Save</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The car then shows at the top of its /buy pages (its make, model, year and trim) with the asking price, the only time a page says a car is for sale.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Untick it when the car is sold or no longer for sale: the pages say so at once.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">&quot;Find me this car&quot; on the /buy pages sends a buyer lead to Sales (staff portal: <b class="gd-ui">Owner leads</b>, Buyer leads), with a To do line.</div></li></ol></div></section><section class="gd-task" id="search-car-pages-landing-pages-and-guides-search-engines-and-business-listings" data-gd-task><h2 class="gd-h2">Search engines and business listings</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">All settings</b>, then Site settings.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Search engines: paste the Google Search Console value (HTML tag) or the file name (HTML file), and the Bing value. The steps are on the card.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Business name, address and phone: the exact text for every listing, and the description and categories.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Business listings: press <b class="gd-ui">Copy</b> beside each line and paste it into Google Business Profile, Bing Places, Apple Business Connect, Yelp, Yellow Pages and Facebook. Tick each one when it is done.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Changed pages are sent to IndexNow (Bing and the other engines that use it) by themselves. Google reads the sitemap: submit carmacars.ca/sitemap.xml once in Search Console.</div></aside></section><section class="gd-task" id="search-car-pages-landing-pages-and-guides-place-pages" data-gd-task><h2 class="gd-h2">Place pages</h2><p class="gd-p">Every place we have, from a country down to a neighbourhood, gets a page for every term people search with: renting (car hire, SUV rental, monthly car rental ...), buying help (used cars, car financing ...), detailing (ceramic coating, window tint ...) and body work (collision repair, dent repair ...). Each page is written from real data only: the distance from us, the delivery price within our reach, the nearest airport, the landmarks near it, our live cars and the places around it. A place far from Toronto says we serve the Toronto area and takes a request instead. <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">All settings</b>, then Search.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Place pages: four switches, one for each family, put the pages in search and in the sitemaps. All four are on.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Quality gate: off. On, only places within the delivery reach are in search, and rental pages only with a real matching car. Search engines can treat many similar pages as low value; the gate lowers that risk.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Delivery reach: places within this distance of our location are offered delivery. Database size cap: the places import stops before the database passes it.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Regions and places: every province, state and territory is on. Untick a region to take its pages and sitemaps off the site.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Terms and services: change a term&#39;s title or what is true about it, point a synonym to another term (its pages then leave search), switch a term off, or add one. Give a service a starting price, or leave it empty for &quot;price on request&quot;.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A region has pages once the places workflow has loaded it: GitHub, Actions, places, Run workflow, with the regions or all. The run loads Ontario first and names any region it skipped because of the size cap.</div></aside></section><section class="gd-task" id="search-car-pages-landing-pages-and-guides-requests-from-the-place-pages" data-gd-task><h2 class="gd-h2">Requests from the place pages</h2><p class="gd-p">The buying help, detailing and body shop pages, and the pages of places beyond our reach, have a request form. Each request is a lead with a task in <b class="gd-ui">To do</b>: detailing and body shop requests are due within an hour of opening and show in Today. Buying help pages say plainly that CarmaCars does not sell, finance or lease cars; the notice at the top is set under Place pages.</p><p class="gd-p">Mechanical work has pages too, under the body shop pages and listed apart as &quot;Auto services we arrange&quot;: a mechanic, oil changes, brakes, tires and winter tires, towing, batteries and boosts, alignment, transmission and engine repair, diagnostics, inspections and the Ontario safety certificate, emissions, AC, exhaust and suspension. CarmaCars does not do this work, and the pages say so: each takes a request (a &quot;Mechanical work to arrange&quot; task, due within an hour of opening) and offers a rental while the car is in. They have no questions of their own; their per car pages (for each make, model, year and trim) say the same and take the same request.</p></section><section class="gd-task" id="search-car-pages-landing-pages-and-guides-one-name-address-and-phone" data-gd-task><h2 class="gd-h2">One name, address and phone</h2><p class="gd-p">The footer, the contact page, the structured data and every business listing show the business address of Site settings. Keep it the address renters come to, and change it there only.</p></section>');
-- GUIDES 0137 END
