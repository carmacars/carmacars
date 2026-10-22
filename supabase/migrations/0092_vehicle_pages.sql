-- 0092: vehicle pages (docs/changes/2026-10-21-vehicle-pages.md).
--
-- A page for every make, model, model year and Canadian trim the site covers, under the fleet's address:
--   /cars/<make>, /cars/<make>/<model>, /cars/<make>/<model>/<year>, /cars/<make>/<model>/<year>/<trim>
-- with the inventory we have below it. The model page replaces the model hub (/rent/<make-model> answers 301), and
-- app.model_hub_path points every car's model link at it.
--
-- 1. The catalog: vehicle_catalog_makes, _models, _years (the EPA powertrains of each model year, with their fuel use),
--    _trim_lines (the Canadian trim names: the list in web/scripts/catalog/canada-trims.txt, and an Admin's lines),
--    _trims (each trim of each model year, tied to its EPA powertrains), _popular (the popular models), _imports and
--    _import_requests. Filled only by the catalog workflow (.github/workflows/catalog.yml) through
--    app.vehicle_catalog_import_begin / _batch / _popular / _finish; every row keeps a content hash, so updated_at
--    (the sitemaps' lastmod) moves only when its data changed.
-- 2. The settings (program_settings vpage_*): every page is indexed by default (the owner, October 21, 2026); "rules"
--    keeps the stricter gate (makes; models with 2 or more years; years with our car or a popular model from 2015;
--    trims with our car), the rest noindex,follow with the canonical at the parent. Gas and electricity prices for
--    the cost of 100 km. How often the catalog is imported.
-- 3. A car of the fleet and its catalog page: app.vehicle_catalog_match (make, model by name or alias, year, the trim
--    by its Canadian name; an unclear trim stays at the year).
-- 4. One read per page level (public.vehicle_make_page, _model_page, _year_page, _trim_page): the catalog data, the
--    neighbours (other years, sibling trims, similar models), the inventory (our exact cars, the same model in other
--    years, similar cars), whether it is indexed and its canonical. public.vehicle_sitemap_files / vehicle_sitemap:
--    the sitemaps by make and level. Anonymous may call them (the pages are public); the app calls them on the server.
-- 5. Admin > Settings > Vehicle pages (the door): counts, settings, the popular list, a model's trim lines, Import now.

-- ================================================================ 1. the catalog
create table vehicle_catalog_makes (
  slug text primary key check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  name text not null,
  import_id uuid,
  content_hash text,
  updated_at timestamptz not null default now()
);

create table vehicle_catalog_models (
  make_slug text not null references vehicle_catalog_makes (slug) on delete cascade,
  slug text not null check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  name text not null,
  key text not null,
  aliases text[] not null default '{}',
  vclass text,
  sources text[] not null default '{}',
  import_id uuid,
  content_hash text,
  updated_at timestamptz not null default now(),
  primary key (make_slug, slug)
);
create index vehicle_catalog_models_key_idx on vehicle_catalog_models (make_slug, key);
create index vehicle_catalog_models_alias_idx on vehicle_catalog_models using gin (aliases);

create table vehicle_catalog_years (
  make_slug text not null,
  model_slug text not null,
  year smallint not null check (year between 1980 and 2100),
  vclass text,
  variants jsonb not null default '[]'::jsonb,
  -- the summary of the powertrains, kept with the row so the lists and the similar models read no JSON
  powertrains smallint not null default 0,
  l100_min numeric(5,1),
  l100_max numeric(5,1),
  kwh100_min numeric(5,1),
  ev_range_max integer,
  fuels text[] not null default '{}',
  drives text[] not null default '{}',
  sources text[] not null default '{}',
  import_id uuid,
  content_hash text,
  updated_at timestamptz not null default now(),
  primary key (make_slug, model_slug, year),
  foreign key (make_slug, model_slug) references vehicle_catalog_models (make_slug, slug) on delete cascade
);
create index vehicle_catalog_years_class_idx on vehicle_catalog_years (vclass, year);
create index vehicle_catalog_years_year_idx on vehicle_catalog_years (year);

create table vehicle_catalog_trim_lines (
  id bigserial primary key,
  make_slug text not null,
  model_slug text not null,
  from_year smallint not null,
  to_year smallint not null,
  trims text[] not null check (cardinality(trims) between 1 and 40),
  source text not null default 'seed' check (source in ('seed', 'admin')),
  sort integer not null default 0,
  updated_by uuid references users (id),
  updated_at timestamptz not null default now(),
  check (to_year >= from_year)
);
create index vehicle_catalog_trim_lines_model_idx on vehicle_catalog_trim_lines (make_slug, model_slug);

create table vehicle_catalog_trims (
  make_slug text not null,
  model_slug text not null,
  year smallint not null,
  slug text not null check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  name text not null,
  rank smallint not null,
  variant_ids integer[] not null default '{}',
  source text not null,
  content_hash text,
  updated_at timestamptz not null default now(),
  primary key (make_slug, model_slug, year, slug),
  foreign key (make_slug, model_slug, year) references vehicle_catalog_years (make_slug, model_slug, year) on delete cascade
);
create index vehicle_catalog_trims_slug_idx on vehicle_catalog_trims (make_slug, model_slug, slug);

create table vehicle_catalog_popular (
  make_slug text not null,
  model_slug text not null,
  sort integer not null default 0,
  added_by uuid references users (id),
  created_at timestamptz not null default now(),
  primary key (make_slug, model_slug)
);

create table vehicle_catalog_imports (
  id uuid primary key default gen_random_uuid(),
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  status text not null default 'running' check (status in ('running', 'done', 'failed')),
  meta jsonb not null default '{}'::jsonb,
  counts jsonb,
  error text
);

create table vehicle_catalog_import_requests (
  id bigserial primary key,
  requested_by uuid references users (id),
  requested_at timestamptz not null default now(),
  import_id uuid references vehicle_catalog_imports (id) on delete set null
);

do $$
declare t text;
begin
  foreach t in array array['vehicle_catalog_makes', 'vehicle_catalog_models', 'vehicle_catalog_years', 'vehicle_catalog_trim_lines', 'vehicle_catalog_trims',
                           'vehicle_catalog_popular', 'vehicle_catalog_imports', 'vehicle_catalog_import_requests'] loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on %I from public, anon, authenticated', t);
    execute format('grant select, insert, update, delete on %I to service_role', t);
  end loop;
end $$;
grant usage on sequence vehicle_catalog_trim_lines_id_seq, vehicle_catalog_import_requests_id_seq to service_role;

-- ================================================================ 2. the settings
alter table program_settings
  add column if not exists vpage_index_mode text not null default 'all' check (vpage_index_mode in ('all', 'rules')),
  add column if not exists vpage_model_min_years integer not null default 2 check (vpage_model_min_years between 1 and 30),
  add column if not exists vpage_popular_from_year integer not null default 2015 check (vpage_popular_from_year between 1990 and 2100),
  add column if not exists vpage_year_min_cars integer not null default 1 check (vpage_year_min_cars between 1 and 100),
  add column if not exists vpage_trim_min_cars integer not null default 1 check (vpage_trim_min_cars between 1 and 100),
  add column if not exists vpage_gas_cents_per_litre integer not null default 155 check (vpage_gas_cents_per_litre between 50 and 500),
  add column if not exists vpage_premium_extra_cents integer not null default 20 check (vpage_premium_extra_cents between 0 and 100),
  add column if not exists vpage_electricity_cents_per_kwh integer not null default 15 check (vpage_electricity_cents_per_kwh between 1 and 100),
  add column if not exists vpage_import_every_days integer not null default 30 check (vpage_import_every_days between 7 and 365);
comment on column program_settings.vpage_index_mode is 'Vehicle pages (0092): "all" indexes every make, model, year and trim page (the default); "rules" indexes only the pages that pass the rules below, the rest noindex,follow with the canonical at the parent page.';
comment on column program_settings.vpage_model_min_years is 'Vehicle pages, rules only: a model page is indexed with at least this many model years of data, or one of our cars.';
comment on column program_settings.vpage_popular_from_year is 'Vehicle pages, rules only: a model year of a popular model is indexed from this year on.';
comment on column program_settings.vpage_year_min_cars is 'Vehicle pages, rules only: a model year page is indexed with this many of our cars of that year (or when the model is popular).';
comment on column program_settings.vpage_trim_min_cars is 'Vehicle pages, rules only: a trim page is indexed with this many of our cars of that exact trim.';
comment on column program_settings.vpage_gas_cents_per_litre is 'Vehicle pages: the price of regular gas in cents a litre, for "cost to drive 100 km".';
comment on column program_settings.vpage_premium_extra_cents is 'Vehicle pages: how much more premium gas costs, in cents a litre, for a car that needs it.';
comment on column program_settings.vpage_electricity_cents_per_kwh is 'Vehicle pages: the price of electricity in cents a kWh (home charging in Ontario), for an electric car''s cost of 100 km.';
comment on column program_settings.vpage_import_every_days is 'Vehicle pages: the catalog (EPA, vPIC and the Canadian trim names) is imported again after this many days. Admin > Settings > Vehicle pages imports it at once.';

-- ================================================================ helpers
create or replace function app.vehicle_trim_slug(p text) returns text
language sql immutable as $$ select app.slugify(replace(coalesce(p, ''), '+', ' plus ')) $$;

create or replace function app.vehicle_model_key(p text) returns text
language sql immutable as $$ select replace(coalesce(app.slugify(p), ''), '-', '') $$;

-- A make as the catalog names it ("Mercedes" and "VW" as their makes).
create or replace function app.vehicle_make_slug(p text) returns text
language sql immutable as $$
  select case app.slugify(p) when 'mercedes' then 'mercedes-benz' when 'vw' then 'volkswagen' when 'chevy' then 'chevrolet'
                             when 'land-rover-range-rover' then 'land-rover' else app.slugify(p) end
$$;

-- The page's address.
create or replace function app.vpage_path(p_make text, p_model text default null, p_year integer default null, p_trim text default null) returns text
language sql immutable as $$
  select '/cars/' || p_make || coalesce('/' || p_model, '') || coalesce('/' || p_year::text, '') || coalesce('/' || p_trim, '')
$$;

-- A kind of body, from the EPA size class, else a listing's body style: similar cars share it.
create or replace function app.vpage_body_group(p_vclass text, p_body text default null) returns text
language sql immutable as $$
  select case
    when lower(coalesce(p_vclass, '')) ~ 'pickup' then 'pickup'
    when lower(coalesce(p_vclass, '')) ~ 'minivan' then 'van'
    when lower(coalesce(p_vclass, '')) ~ 'sport utility' then 'suv'
    when lower(coalesce(p_vclass, '')) ~ 'van|special purpose' then 'van'
    when lower(coalesce(p_vclass, '')) ~ 'wagon' then 'wagon'
    when lower(coalesce(p_vclass, '')) ~ 'two seaters|minicompact' then 'sports'
    when p_vclass is not null then 'car'
    when lower(coalesce(p_body, '')) ~ 'pickup|truck' then 'pickup'
    when lower(coalesce(p_body, '')) ~ 'van|minivan' then 'van'
    when lower(coalesce(p_body, '')) ~ 'suv|sport utility|crossover' then 'suv'
    when lower(coalesce(p_body, '')) ~ 'wagon' then 'wagon'
    when lower(coalesce(p_body, '')) ~ 'convertible|roadster|coupe' then 'sports'
    else 'car' end
$$;

create or replace function app.vpage_premium(p_make text) returns boolean
language sql immutable as $$
  select p_make = any (array['acura', 'alfa-romeo', 'audi', 'bmw', 'cadillac', 'genesis', 'infiniti', 'jaguar', 'land-rover', 'lexus', 'lincoln',
                             'lucid', 'mercedes-benz', 'polestar', 'porsche', 'rivian', 'tesla', 'volvo', 'maserati'])
$$;

-- True when the words of a car's trim begin with the trim's name, at a word boundary ("Comfortline Sport" is a
-- Comfortline, "C300 4MATIC Sedan" a "C 300 4MATIC"; "SEL" is not an "S").
create or replace function app.vpage_token_prefix(p_text text, p_compact text) returns boolean
language sql immutable as $$
  select coalesce(p_compact, '') <> '' and exists (
    select 1 from (select string_to_array(coalesce(app.slugify(p_text), ''), '-') t) x, generate_series(1, coalesce(array_length(x.t, 1), 0)) k
     where array_to_string(x.t[1:k], '') = p_compact)
$$;

-- The EPA powertrains of a model year that a trim name stands for. Each powertrain's own words (EPA's model name
-- beyond the base model: Hybrid, GLI, Long Range, C300; "SE/XLE/XSE" is one word with alternatives) score +1 when the
-- trim names them and -1 when it does not; the best score wins, then the fewest words (so "LE" is the gas Camry,
-- "Hybrid LE" the hybrid). A package named "<X> Line" (N Line, GT-Line, R-Line, ST-Line) does not name X's powertrain.
-- A trim that says Hybrid (or Prime, Plug-in) keeps only those powertrains, and none when the year has none; a trim
-- that does not keeps the others when there are others. AWD (4MATIC, xDrive, quattro...), rear-wheel drive or manual
-- keep those powertrains when the year has them.
create or replace function app.vehicle_trim_variants(p_variants jsonb, p_name text) returns integer[]
language plpgsql immutable as $$
declare
  v_raw text[] := string_to_array(coalesce(app.slugify(p_name), ''), '-');
  v_tok text[] := '{}';
  v_all text[];
  v_ids integer[];
  v_drive text;
  v_try integer[];
  v_fuel text[];
  i integer;
begin
  if jsonb_typeof(p_variants) is distinct from 'array' or jsonb_array_length(p_variants) = 0 then return '{}'; end if;
  -- "N Line", "GT-Line": the word before "line" and "line" itself name a package, not a powertrain
  for i in 1 .. coalesce(array_length(v_raw, 1), 0) loop
    if v_raw[i] = 'line' or (i < array_length(v_raw, 1) and v_raw[i + 1] = 'line') then continue; end if;
    v_tok := v_tok || v_raw[i];
  end loop;
  -- the trim's words, and each two and three words run together ("c 300" is "c300")
  v_all := v_tok || array(select v_tok[k] || v_tok[k + 1] from generate_series(1, coalesce(array_length(v_tok, 1), 0) - 1) k)
                 || array(select v_tok[k] || v_tok[k + 1] || v_tok[k + 2] from generate_series(1, coalesce(array_length(v_tok, 1), 0) - 2) k);
  v_fuel := case when p_name ~* 'prime|plug.?in|phev|4xe' then array['plug_in_hybrid']
                 when p_name ~* '\mhybrid\M' then array['hybrid', 'plug_in_hybrid']
                 when p_name ~* '\m(ev|electric)\M' then array['electric'] end;
  with e as (select (x ->> 'id')::integer id, x ->> 'fuel' fuel, x -> 'special' sp from jsonb_array_elements(p_variants) x),
       f as (select * from e where case when v_fuel is not null then e.fuel = any (v_fuel)
                                        when exists (select 1 from e e2 where e2.fuel not in ('hybrid', 'plug_in_hybrid')) then e.fuel not in ('hybrid', 'plug_in_hybrid')
                                        else true end),
       s as (select f.id,
           coalesce((select count(*) from jsonb_array_elements_text(f.sp) w where string_to_array(w, '|') && v_all), 0)
         - coalesce((select count(*) from jsonb_array_elements_text(f.sp) w where not (string_to_array(w, '|') && v_all)), 0) score,
           jsonb_array_length(coalesce(f.sp, '[]'::jsonb)) words
      from f),
  best as (select max(score) m from s),
  b2 as (select min(words) w from s, best where s.score = best.m)
  select array_agg(s.id order by s.id) into v_ids from s, best, b2 where s.score = best.m and s.words = b2.w;
  v_drive := case when v_tok && array['awd', '4wd', '4x4', 'xdrive', '4matic', 'quattro', '4motion', 'all4', 'sh'] then 'awd'
                  when p_name ~* 'rear.?wheel|\mrwd\M' then 'rwd' end;
  if v_drive is not null then
    select array_agg(id order by id) into v_try from (select (x ->> 'id')::integer id, x ->> 'drive' d from jsonb_array_elements(p_variants) x) y
     where y.id = any (v_ids) and case v_drive when 'awd' then y.d ~* 'all|4-wheel|4wd|awd' else y.d ~* 'rear|2-wheel' end;
    if v_try is not null then v_ids := v_try; end if;
  end if;
  if p_name ~* '\mmanual\M' then
    select array_agg(id order by id) into v_try from (select (x ->> 'id')::integer id, x ->> 'trans' t from jsonb_array_elements(p_variants) x) y
     where y.id = any (v_ids) and y.t ~* '^manual';
    if v_try is not null then v_ids := v_try; end if;
  end if;
  return coalesce(v_ids, '{}');
end $$;

-- The trims of one model (or every model), from its trim lines: an Admin's lines when the model has any, else the list's.
-- Only model years the catalog has get trims; the first line naming a trim in a year wins.
create or replace function app.vehicle_catalog_build_trims(p_make text default null, p_model text default null) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  n integer;
begin
  create temporary table if not exists vpage_new_trims (make_slug text, model_slug text, year smallint, slug text, name text, rank smallint, variant_ids integer[], source text) on commit drop;
  truncate vpage_new_trims;
  insert into vpage_new_trims
  select distinct on (l.make_slug, l.model_slug, y.year, app.vehicle_trim_slug(t.name))
         l.make_slug, l.model_slug, y.year, app.vehicle_trim_slug(t.name), btrim(t.name),
         (row_number() over (partition by l.make_slug, l.model_slug, y.year order by l.sort, l.id, t.ord))::smallint,
         app.vehicle_trim_variants(y.variants, t.name), l.source
    from vehicle_catalog_trim_lines l
    cross join lateral unnest(l.trims) with ordinality t(name, ord)
    join vehicle_catalog_years y on y.make_slug = l.make_slug and y.model_slug = l.model_slug and y.year between l.from_year and l.to_year
   where (p_make is null or l.make_slug = p_make) and (p_model is null or l.model_slug = p_model)
     and app.vehicle_trim_slug(t.name) is not null
     and (l.source = 'admin' or not exists (select 1 from vehicle_catalog_trim_lines a where a.make_slug = l.make_slug and a.model_slug = l.model_slug and a.source = 'admin'))
   order by l.make_slug, l.model_slug, y.year, app.vehicle_trim_slug(t.name), l.sort, l.id, t.ord;
  -- a performance trim EPA does not separate in some years ("Jetta" with the GLI's 2.0L in 2020, "Jetta GLI" in 2019 and
  -- 2021): when exactly one trim of the year is named by a word EPA uses for this model in another year, and every
  -- trim of the year has the same powertrains with two or more engine sizes, that trim takes the largest engine and the
  -- others the rest
  with yr as (select n.make_slug, n.model_slug, n.year from vpage_new_trims n group by 1, 2, 3
               having count(distinct n.variant_ids) = 1 and count(*) > 1),
       words as (select y.make_slug, y.model_slug, w from vehicle_catalog_years y, jsonb_array_elements(y.variants) v, jsonb_array_elements_text(v -> 'special') w0,
                        unnest(string_to_array(w0, '|')) w group by 1, 2, 3),
       perf as (select n.make_slug, n.model_slug, n.year, min(n.slug) slug from vpage_new_trims n join yr using (make_slug, model_slug, year)
                 where exists (select 1 from words w where (w.make_slug, w.model_slug) = (n.make_slug, n.model_slug) and w.w = app.vehicle_model_key(n.name))
                 group by 1, 2, 3 having count(*) = 1),
       sizes as (select p.make_slug, p.model_slug, p.year, p.slug, max((v ->> 'displ')::numeric) big, count(distinct (v ->> 'displ')) n
                   from perf p join vehicle_catalog_years y using (make_slug, model_slug, year), jsonb_array_elements(y.variants) v group by 1, 2, 3, 4)
  update vpage_new_trims n
     set variant_ids = coalesce((select array_agg((v ->> 'id')::integer order by (v ->> 'id')::integer) from vehicle_catalog_years y, jsonb_array_elements(y.variants) v
                                  where (y.make_slug, y.model_slug, y.year) = (n.make_slug, n.model_slug, n.year) and (v ->> 'id')::integer = any (n.variant_ids)
                                    and case when n.slug = z.slug then (v ->> 'displ')::numeric = z.big else (v ->> 'displ')::numeric < z.big end), n.variant_ids)
    from sizes z where (z.make_slug, z.model_slug, z.year) = (n.make_slug, n.model_slug, n.year) and z.n >= 2;
  -- ranks again without gaps after the duplicates went
  update vpage_new_trims n set rank = r.rk from (
    select make_slug, model_slug, year, slug, (row_number() over (partition by make_slug, model_slug, year order by rank))::smallint rk from vpage_new_trims) r
   where (n.make_slug, n.model_slug, n.year, n.slug) = (r.make_slug, r.model_slug, r.year, r.slug);
  delete from vehicle_catalog_trims t
   where (p_make is null or t.make_slug = p_make) and (p_model is null or t.model_slug = p_model)
     and not exists (select 1 from vpage_new_trims n where (n.make_slug, n.model_slug, n.year, n.slug) = (t.make_slug, t.model_slug, t.year, t.slug));
  insert into vehicle_catalog_trims (make_slug, model_slug, year, slug, name, rank, variant_ids, source, content_hash)
  select make_slug, model_slug, year, slug, name, rank, variant_ids, source, md5(concat_ws('|', name, rank, variant_ids::text)) from vpage_new_trims
  on conflict (make_slug, model_slug, year, slug) do update
    set name = excluded.name, rank = excluded.rank, variant_ids = excluded.variant_ids, source = excluded.source, content_hash = excluded.content_hash,
        updated_at = case when vehicle_catalog_trims.content_hash is distinct from excluded.content_hash then now() else vehicle_catalog_trims.updated_at end;
  select count(*) into n from vpage_new_trims;
  return n;
end $$;

-- ================================================================ the import (the catalog workflow only)
create or replace function app.vehicle_catalog_import_begin(p jsonb) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid;
begin
  update vehicle_catalog_imports set status = 'failed', finished_at = now(), error = 'Replaced by a newer import' where status = 'running';
  insert into vehicle_catalog_imports (meta) values (coalesce(p, '{}'::jsonb)) returning id into v_id;
  update vehicle_catalog_import_requests set import_id = v_id where import_id is null;
  return v_id;
end $$;

create or replace function app.vehicle_catalog_running() returns uuid
language sql stable security definer set search_path = public, app as $$
  select id from vehicle_catalog_imports where status = 'running' order by started_at desc limit 1
$$;

-- One make: the make, its models, its model years with their powertrains, and the list's trim lines.
create or replace function app.vehicle_catalog_import_batch(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_imp uuid := app.vehicle_catalog_running();
  v_make text := p -> 'make' ->> 'slug';
  n_models integer; n_years integer;
begin
  if v_imp is null then raise exception 'No import is running' using errcode = '55000'; end if;
  if v_make is null then raise exception 'A batch names its make' using errcode = '22023'; end if;
  insert into vehicle_catalog_makes (slug, name, import_id, content_hash)
  values (v_make, p -> 'make' ->> 'name', v_imp, md5(p -> 'make' ->> 'name'))
  on conflict (slug) do update set name = excluded.name, import_id = excluded.import_id, content_hash = excluded.content_hash,
    updated_at = case when vehicle_catalog_makes.content_hash is distinct from excluded.content_hash then now() else vehicle_catalog_makes.updated_at end;

  insert into vehicle_catalog_models (make_slug, slug, name, key, aliases, vclass, sources, import_id, content_hash)
  select v_make, m ->> 'slug', m ->> 'name', m ->> 'key', array(select jsonb_array_elements_text(m -> 'aliases')), m ->> 'vclass',
         array(select jsonb_array_elements_text(m -> 'sources')), v_imp, md5((m - 'make')::text)
    from jsonb_array_elements(coalesce(p -> 'models', '[]'::jsonb)) m
  on conflict (make_slug, slug) do update set name = excluded.name, key = excluded.key, aliases = excluded.aliases, vclass = excluded.vclass,
    sources = excluded.sources, import_id = excluded.import_id, content_hash = excluded.content_hash,
    updated_at = case when vehicle_catalog_models.content_hash is distinct from excluded.content_hash then now() else vehicle_catalog_models.updated_at end;
  get diagnostics n_models = row_count;

  insert into vehicle_catalog_years (make_slug, model_slug, year, vclass, variants, powertrains, l100_min, l100_max, kwh100_min, ev_range_max, fuels, drives,
                                     sources, import_id, content_hash)
  select v_make, y ->> 'model', (y ->> 'year')::smallint, y ->> 'vclass', coalesce(y -> 'variants', '[]'::jsonb),
         jsonb_array_length(coalesce(y -> 'variants', '[]'::jsonb)),
         (select min((v ->> 'l100_comb')::numeric) from jsonb_array_elements(y -> 'variants') v),
         (select max((v ->> 'l100_comb')::numeric) from jsonb_array_elements(y -> 'variants') v),
         (select min((v ->> 'kwh100')::numeric) from jsonb_array_elements(y -> 'variants') v),
         (select max((v ->> 'ev_range_km')::integer) from jsonb_array_elements(y -> 'variants') v),
         array(select distinct case v ->> 'fuel' when 'premium' then 'gasoline' else v ->> 'fuel' end from jsonb_array_elements(y -> 'variants') v order by 1),
         array(select distinct v ->> 'drive' from jsonb_array_elements(y -> 'variants') v where v ->> 'drive' is not null order by 1),
         array(select jsonb_array_elements_text(y -> 'sources')), v_imp, md5((y - 'make')::text)
    from jsonb_array_elements(coalesce(p -> 'years', '[]'::jsonb)) y
  on conflict (make_slug, model_slug, year) do update set vclass = excluded.vclass, variants = excluded.variants, powertrains = excluded.powertrains,
    l100_min = excluded.l100_min, l100_max = excluded.l100_max, kwh100_min = excluded.kwh100_min, ev_range_max = excluded.ev_range_max,
    fuels = excluded.fuels, drives = excluded.drives, sources = excluded.sources, import_id = excluded.import_id, content_hash = excluded.content_hash,
    updated_at = case when vehicle_catalog_years.content_hash is distinct from excluded.content_hash then now() else vehicle_catalog_years.updated_at end;
  get diagnostics n_years = row_count;

  -- the list's trim lines for this make, as the list now has them (an Admin's lines are never touched)
  delete from vehicle_catalog_trim_lines where make_slug = v_make and source = 'seed';
  insert into vehicle_catalog_trim_lines (make_slug, model_slug, from_year, to_year, trims, source, sort)
  select v_make, t ->> 'model', (t ->> 'from')::smallint, (t ->> 'to')::smallint, array(select jsonb_array_elements_text(t -> 'trims')), 'seed', i::integer
    from jsonb_array_elements(coalesce(p -> 'trim_lines', '[]'::jsonb)) with ordinality x(t, i);
  return jsonb_build_object('make', v_make, 'models', n_models, 'years', n_years);
end $$;

-- The popular list: models it does not have yet are added at the end (an Admin's edits stay).
create or replace function app.vehicle_catalog_import_popular(p jsonb) returns integer
language plpgsql security definer set search_path = public, app as $$
declare n integer;
begin
  insert into vehicle_catalog_popular (make_slug, model_slug, sort)
  select e ->> 'make', e ->> 'model', coalesce((select max(sort) from vehicle_catalog_popular), 0) + (e ->> 'sort')::integer
    from jsonb_array_elements(coalesce(p, '[]'::jsonb)) e
   where not exists (select 1 from vehicle_catalog_popular_removed r where r.make_slug = e ->> 'make' and r.model_slug = e ->> 'model')
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

-- An Admin's removals from the popular list, so the next import does not add the model back.
create table vehicle_catalog_popular_removed (
  make_slug text not null,
  model_slug text not null,
  removed_by uuid references users (id),
  removed_at timestamptz not null default now(),
  primary key (make_slug, model_slug)
);
alter table vehicle_catalog_popular_removed enable row level security;
revoke all on vehicle_catalog_popular_removed from public, anon, authenticated;
grant select, insert, update, delete on vehicle_catalog_popular_removed to service_role;

-- every table: the admin policy (the site's rule, suite 04); the lists an Admin edits are audited (suite 03), the rows
-- the import writes in bulk are not (reference data from public sources, thousands of rows a month)
do $$
declare t text;
begin
  foreach t in array array['vehicle_catalog_makes', 'vehicle_catalog_models', 'vehicle_catalog_years', 'vehicle_catalog_trim_lines', 'vehicle_catalog_trims',
                           'vehicle_catalog_popular', 'vehicle_catalog_imports', 'vehicle_catalog_import_requests', 'vehicle_catalog_popular_removed'] loop
    execute format('create policy admin_all on %I for all to authenticated using (app.is_admin()) with check (app.is_admin())', t);
  end loop;
  foreach t in array array['vehicle_catalog_trim_lines', 'vehicle_catalog_popular', 'vehicle_catalog_popular_removed', 'vehicle_catalog_import_requests'] loop
    execute format('create trigger audit_%s after insert or update or delete on %I for each row execute function app.audit_row()', t, t);
  end loop;
end $$;

-- The end of an import: what this import did not bring (a make, model or year gone from the sources) is removed, the
-- trims are built again, and the import is recorded with its counts.
create or replace function app.vehicle_catalog_import_finish(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_imp uuid := app.vehicle_catalog_running();
  v_makes text[] := array(select jsonb_array_elements_text(coalesce(p -> 'makes', '[]'::jsonb)));
  v_counts jsonb;
begin
  if v_imp is null then raise exception 'No import is running' using errcode = '55000'; end if;
  if cardinality(v_makes) = 0 then raise exception 'An import with no make is refused (the catalog would be emptied)' using errcode = '22023'; end if;
  delete from vehicle_catalog_makes where not (slug = any (v_makes));
  delete from vehicle_catalog_models where import_id is distinct from v_imp;
  delete from vehicle_catalog_years where import_id is distinct from v_imp;
  perform app.vehicle_catalog_build_trims();
  v_counts := jsonb_build_object('makes', (select count(*) from vehicle_catalog_makes), 'models', (select count(*) from vehicle_catalog_models),
    'years', (select count(*) from vehicle_catalog_years), 'trims', (select count(*) from vehicle_catalog_trims),
    'trim_lines', (select count(*) from vehicle_catalog_trim_lines), 'popular', (select count(*) from vehicle_catalog_popular));
  update vehicle_catalog_imports set status = 'done', finished_at = now(), counts = v_counts where id = v_imp;
  return v_counts;
end $$;

create or replace function app.vehicle_catalog_import_fail(p jsonb) returns void
language sql security definer set search_path = public, app as $$
  update vehicle_catalog_imports set status = 'failed', finished_at = now(), error = left(coalesce(p ->> 'error', 'failed'), 1000) where status = 'running'
$$;

-- The daily check of the catalog workflow: an import is due when an Admin asked for one, or the last one is older than
-- the setting (30 days: monthly).
create or replace function app.vehicle_catalog_import_due() returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from vehicle_catalog_import_requests where import_id is null)
      or coalesce((select max(finished_at) from vehicle_catalog_imports where status = 'done'), '-infinity'::timestamptz)
         < now() - make_interval(days => (app.settings()).vpage_import_every_days)
$$;

-- ================================================================ 3. a car of the fleet and its catalog page
-- make: the catalog's (or the car's own make as a slug); model: by name, by EPA alias ("C300" is the C-Class), else the
-- car's own model as a slug; trim: the year's trim its words name, when exactly one does (an unclear "S / SE / R-Line"
-- stays at the year).
create or replace function app.vehicle_catalog_match(p_make text, p_model text, p_year integer, p_trim text)
returns table (make_slug text, model_slug text, trim_slug text, in_catalog boolean)
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_make text := app.vehicle_make_slug(p_make);
  v_key text := app.vehicle_model_key(p_model);
  v_model text;
  v_trim text;
begin
  select m.slug into v_model from vehicle_catalog_models m
   where m.make_slug = v_make and (m.key = v_key or v_key = any (m.aliases))
   order by (m.key = v_key) desc, m.slug limit 1;
  if v_model is null then
    return query select v_make, app.slugify(p_model), null::text, false;
    return;
  end if;
  if nullif(btrim(coalesce(p_trim, '')), '') is not null then
    with parts as (select btrim(x) part from regexp_split_to_table(p_trim, '\s*[,/]\s*') x where btrim(x) <> ''),
         hits as (
           select p.part, (select t.slug from vehicle_catalog_trims t
                            where t.make_slug = v_make and t.model_slug = v_model and t.year = p_year
                              and (app.vpage_token_prefix(p.part, app.vehicle_model_key(t.name)) or app.vpage_token_prefix(p_model || ' ' || p.part, app.vehicle_model_key(t.name))
                                   or app.vehicle_trim_slug(p.part) = t.slug)
                            order by length(app.vehicle_model_key(t.name)) desc limit 1) slug
             from parts p)
    select case when count(distinct h.slug) = 1 and count(*) filter (where h.slug is null) = 0 then min(h.slug) end into v_trim from hits h;
  end if;
  return query select v_make, v_model, v_trim, true;
end $$;

-- The cars on the site (as the fleet page lists them) with their catalog page, body group and daily rate.
create or replace function app.vpage_cars() returns table (vehicle_id uuid, is_sample boolean, make_slug text, model_slug text, year integer, trim_slug text,
  body_group text, premium boolean, daily_rate_cents bigint, first_published_at timestamptz, content_updated_at timestamptz)
language sql stable security definer set search_path = public, app as $$
  select v.id, v.is_sample, m.make_slug, m.model_slug, v.year, m.trim_slug,
         app.vpage_body_group((select y.vclass from vehicle_catalog_years y where y.make_slug = m.make_slug and y.model_slug = m.model_slug and y.year = v.year),
                              coalesce(l.body_style, v.body_type)),
         app.vpage_premium(m.make_slug), rc.daily_rate_cents, l.first_published_at, l.content_updated_at
    from vehicle_listings l join vehicles v on v.id = l.vehicle_id
    cross join lateral app.vehicle_catalog_match(v.make, v.model, v.year, v.trim) m
    left join lateral (select r.daily_rate_cents from rate_cards r where r.vehicle_id = v.id and r.effective_from <= now() and (r.effective_to is null or r.effective_to > now())
                        order by r.effective_from desc limit 1) rc on true
   where l.status = 'published' and v.management_mode <> 'turo_only' and l.slug is not null
$$;

-- ================================================================ the gate
-- Every page is indexed in "all" (the default). In "rules": makes always; a model with enough years of data or a real
-- car of ours; a year with enough real cars of ours, or of a popular model from the set year; a trim with enough real
-- cars of ours. A page that is not indexed is noindex,follow with its canonical at the parent.
create or replace function app.vpage_gate(p_level text, p_years integer, p_real_cars integer, p_popular boolean, p_year integer, s program_settings) returns boolean
language sql immutable as $$
  select s.vpage_index_mode = 'all' or case p_level
    when 'make' then true
    when 'model' then p_years >= s.vpage_model_min_years or p_real_cars >= 1
    when 'year' then p_real_cars >= s.vpage_year_min_cars or (p_popular and p_year >= s.vpage_popular_from_year)
    when 'trim' then p_real_cars >= s.vpage_trim_min_cars
    else false end
$$;

create or replace function app.vpage_settings_json(s program_settings) returns jsonb
language sql immutable as $$
  select jsonb_build_object('index_mode', s.vpage_index_mode, 'model_min_years', s.vpage_model_min_years, 'popular_from_year', s.vpage_popular_from_year,
    'year_min_cars', s.vpage_year_min_cars, 'trim_min_cars', s.vpage_trim_min_cars, 'gas_cents', s.vpage_gas_cents_per_litre,
    'premium_extra_cents', s.vpage_premium_extra_cents, 'elec_cents', s.vpage_electricity_cents_per_kwh)
$$;

-- The inventory block: our cars of the exact page first (p_exact), then the same model in other years (p_model_too),
-- then similar cars (same body group; the same price band, premium or not, first; the nearest daily rate).
create or replace function app.vpage_inventory(p_make text, p_model text, p_year integer, p_trim text, p_group text, p_premium boolean) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with c as materialized (select * from app.vpage_cars()),
       exact as (select * from c where c.make_slug = p_make and (p_model is null or c.model_slug = p_model) and (p_year is null or c.year = p_year)
                                   and (p_trim is null or c.trim_slug = p_trim)),
       same as (select * from c where p_model is not null and c.make_slug = p_make and c.model_slug = p_model and not exists (select 1 from exact e where e.vehicle_id = c.vehicle_id)),
       ref as (select coalesce((select min(daily_rate_cents) from exact), (select min(daily_rate_cents) from same),
                               (select percentile_disc(0.5) within group (order by daily_rate_cents) from c where c.premium = p_premium)) cents),
       sim as (select c.* from c, ref where not exists (select 1 from exact e where e.vehicle_id = c.vehicle_id) and not exists (select 1 from same s where s.vehicle_id = c.vehicle_id)
                order by (c.body_group = p_group) desc, (c.premium = p_premium) desc, abs(coalesce(c.daily_rate_cents, 0) - coalesce(ref.cents, 0)), c.first_published_at limit 6)
  select jsonb_build_object(
    'exact', coalesce((select jsonb_agg(app.public_listing_row(e.vehicle_id) || jsonb_build_object('trim_slug', e.trim_slug) order by e.is_sample, e.daily_rate_cents nulls last, e.first_published_at) from exact e), '[]'::jsonb),
    'same_model', coalesce((select jsonb_agg(app.public_listing_row(s.vehicle_id) order by abs(s.year - coalesce(p_year, s.year)), s.is_sample, s.daily_rate_cents nulls last) from (select * from same limit 6) s), '[]'::jsonb),
    'similar', coalesce((select jsonb_agg(app.public_listing_row(s.vehicle_id) order by (s.body_group = p_group) desc, (s.premium = p_premium) desc, s.daily_rate_cents nulls last) from sim s), '[]'::jsonb),
    'real_exact', (select count(*) from exact where not is_sample),
    'lastmod', (select max(content_updated_at) from exact where not is_sample))
$$;

-- ================================================================ 4. one read per page level
-- A make: its models with their years and fuel use, our cars of the make.
create or replace function app.vehicle_make_page(p_make text) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  mk vehicle_catalog_makes;
  v_inv jsonb;
  v_fleet_name text;
begin
  select * into mk from vehicle_catalog_makes where slug = lower(btrim(p_make));
  if mk.slug is null then
    -- a make the catalog does not cover, while one of our cars is that make (the page lists our cars)
    select min(v.make) into v_fleet_name from app.vpage_cars() c join vehicles v on v.id = c.vehicle_id where c.make_slug = lower(btrim(p_make));
    if v_fleet_name is null then return null; end if;
    mk.slug := lower(btrim(p_make)); mk.name := v_fleet_name; mk.updated_at := null;
  end if;
  v_inv := app.vpage_inventory(mk.slug, null, null, null, 'car', app.vpage_premium(mk.slug));
  return jsonb_build_object(
    'level', 'make', 'make', jsonb_build_object('slug', mk.slug, 'name', mk.name), 'path', app.vpage_path(mk.slug),
    'models', coalesce((select jsonb_agg(jsonb_build_object('slug', m.slug, 'name', m.name, 'vclass', m.vclass, 'path', app.vpage_path(mk.slug, m.slug),
                 'first_year', y.first_year, 'last_year', y.last_year, 'years', y.n, 'l100_min', y.l100_min, 'kwh100_min', y.kwh100_min, 'ev_range_max', y.ev_range_max,
                 'fuels', y.fuels, 'trims', (select count(distinct t.slug) from vehicle_catalog_trims t where t.make_slug = mk.slug and t.model_slug = m.slug))
               order by y.last_year desc, m.name)
          from vehicle_catalog_models m
          join lateral (select min(year) first_year, max(year) last_year, count(*) n, min(l100_min) l100_min, min(kwh100_min) kwh100_min, max(ev_range_max) ev_range_max,
                               array(select distinct f from vehicle_catalog_years yy, unnest(yy.fuels) f where yy.make_slug = m.make_slug and yy.model_slug = m.slug order by 1) fuels
                          from vehicle_catalog_years yy where yy.make_slug = m.make_slug and yy.model_slug = m.slug) y on y.n > 0
         where m.make_slug = mk.slug), '[]'::jsonb),
    'inventory', v_inv, 'settings', app.vpage_settings_json(s),
    'indexable', app.vpage_gate('make', 0, (v_inv ->> 'real_exact')::integer, false, null, s), 'canonical', app.vpage_path(mk.slug),
    'lastmod', greatest(mk.updated_at, (select max(updated_at) from vehicle_catalog_models where make_slug = mk.slug), (v_inv ->> 'lastmod')::timestamptz));
end $$;

-- A model's years in brief (the model page's table, and the other years on the year and trim pages).
create or replace function app.vpage_year_rows(p_make text, p_model text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('year', y.year, 'path', app.vpage_path(y.make_slug, y.model_slug, y.year), 'vclass', y.vclass,
           'powertrains', y.powertrains, 'l100_min', y.l100_min, 'l100_max', y.l100_max, 'kwh100_min', y.kwh100_min, 'ev_range_max', y.ev_range_max,
           'fuels', y.fuels, 'drives', y.drives,
           'engines', (select coalesce(jsonb_agg(distinct jsonb_build_object('displ', v -> 'displ', 'cyl', v -> 'cyl', 'turbo', v -> 'turbo', 'fuel', v ->> 'fuel')), '[]'::jsonb)
                         from jsonb_array_elements(y.variants) v),
           'trims', (select coalesce(jsonb_agg(jsonb_build_object('slug', t.slug, 'name', t.name) order by t.rank), '[]'::jsonb)
                       from vehicle_catalog_trims t where t.make_slug = y.make_slug and t.model_slug = y.model_slug and t.year = y.year))
         order by y.year desc), '[]'::jsonb)
    from vehicle_catalog_years y where y.make_slug = p_make and y.model_slug = p_model
$$;

-- Models like this one: the same size class in the same model year, the same price band first, the nearest fuel use.
create or replace function app.vpage_similar_models(p_make text, p_model text, p_year integer, p_vclass text, p_l100 numeric, p_kwh numeric) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(x.j order by x.ord), '[]'::jsonb) from (
    select jsonb_build_object('make', mk.name, 'model', m.name, 'year', y.year, 'path', app.vpage_path(y.make_slug, y.model_slug, y.year), 'l100_min', y.l100_min,
                              'kwh100_min', y.kwh100_min, 'ev_range_max', y.ev_range_max, 'fuels', y.fuels) j,
           row_number() over (order by (app.vpage_premium(y.make_slug) = app.vpage_premium(p_make)) desc,
                                       abs(coalesce(y.l100_min, 0) - coalesce(p_l100, 0)) + abs(coalesce(y.kwh100_min, 0) - coalesce(p_kwh, 0)), m.name) ord
      from vehicle_catalog_years y join vehicle_catalog_models m on m.make_slug = y.make_slug and m.slug = y.model_slug
      join vehicle_catalog_makes mk on mk.slug = y.make_slug
     where p_vclass is not null and y.vclass = p_vclass and y.year = p_year and not (y.make_slug = p_make and y.model_slug = p_model) and y.powertrains > 0
     order by 2 limit 6) x
$$;

create or replace function app.vpage_is_popular(p_make text, p_model text) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from vehicle_catalog_popular p where p.make_slug = p_make and p.model_slug = p_model)
$$;

-- A model: every year in brief, our cars of the model, similar models of its latest year.
create or replace function app.vehicle_model_page(p_make text, p_model text) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  v_make text := lower(btrim(p_make));
  v_model text := lower(btrim(p_model));
  m vehicle_catalog_models;
  mk vehicle_catalog_makes;
  ly vehicle_catalog_years;
  v_inv jsonb;
  v_years integer;
  v_name text; v_make_name text;
begin
  select * into m from vehicle_catalog_models where make_slug = v_make and slug = v_model;
  if m.slug is null then
    -- another spelling of a model the catalog has ("f150", "c300"): its page answers 301
    select * into m from vehicle_catalog_models x where x.make_slug = v_make and (x.key = app.vehicle_model_key(v_model) or app.vehicle_model_key(v_model) = any (x.aliases))
     order by (x.key = app.vehicle_model_key(v_model)) desc limit 1;
    if m.slug is not null then return jsonb_build_object('redirect', app.vpage_path(m.make_slug, m.slug)); end if;
    -- a model only our fleet has (not in the catalog): the page lists our cars
    select min(v.make), min(v.model) into v_make_name, v_name from app.vpage_cars() c join vehicles v on v.id = c.vehicle_id where c.make_slug = v_make and c.model_slug = v_model;
    if v_name is null then return null; end if;
  else
    v_name := m.name;
  end if;
  select * into mk from vehicle_catalog_makes where slug = v_make;
  select * into ly from vehicle_catalog_years where make_slug = v_make and model_slug = v_model and powertrains > 0 order by year desc limit 1;
  select count(*) filter (where powertrains > 0) into v_years from vehicle_catalog_years where make_slug = v_make and model_slug = v_model;
  v_inv := app.vpage_inventory(v_make, v_model, null, null, app.vpage_body_group(coalesce(ly.vclass, m.vclass)), app.vpage_premium(v_make));
  return jsonb_build_object(
    'level', 'model', 'make', jsonb_build_object('slug', v_make, 'name', coalesce(mk.name, v_make_name)), 'model', jsonb_build_object('slug', v_model, 'name', v_name, 'vclass', m.vclass),
    'path', app.vpage_path(v_make, v_model), 'in_catalog', m.slug is not null, 'years', app.vpage_year_rows(v_make, v_model), 'years_with_data', v_years,
    'popular', app.vpage_is_popular(v_make, v_model), 'body_group', app.vpage_body_group(coalesce(ly.vclass, m.vclass)),
    'similar_models', case when ly.year is not null then app.vpage_similar_models(v_make, v_model, ly.year, ly.vclass, ly.l100_min, ly.kwh100_min) else '[]'::jsonb end,
    'inventory', v_inv, 'settings', app.vpage_settings_json(s),
    'indexable', app.vpage_gate('model', v_years, (v_inv ->> 'real_exact')::integer, false, null, s),
    'canonical', case when app.vpage_gate('model', v_years, (v_inv ->> 'real_exact')::integer, false, null, s) then app.vpage_path(v_make, v_model) else app.vpage_path(v_make) end,
    'lastmod', greatest(m.updated_at, (select max(updated_at) from vehicle_catalog_years where make_slug = v_make and model_slug = v_model), (v_inv ->> 'lastmod')::timestamptz));
end $$;

-- A model year: its powertrains, its trims, the year before and after, the model's other years, similar models.
create or replace function app.vehicle_year_page(p_make text, p_model text, p_year integer) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  y vehicle_catalog_years;
  m vehicle_catalog_models;
  mk vehicle_catalog_makes;
  v_inv jsonb;
  v_ok boolean;
begin
  select * into y from vehicle_catalog_years where make_slug = lower(btrim(p_make)) and model_slug = lower(btrim(p_model)) and year = p_year;
  if y.year is null then return null; end if;
  select * into m from vehicle_catalog_models where make_slug = y.make_slug and slug = y.model_slug;
  select * into mk from vehicle_catalog_makes where slug = y.make_slug;
  v_inv := app.vpage_inventory(y.make_slug, y.model_slug, y.year, null, app.vpage_body_group(coalesce(y.vclass, m.vclass)), app.vpage_premium(y.make_slug));
  v_ok := app.vpage_gate('year', 0, (v_inv ->> 'real_exact')::integer, app.vpage_is_popular(y.make_slug, y.model_slug), y.year, s);
  return jsonb_build_object(
    'level', 'year', 'make', jsonb_build_object('slug', mk.slug, 'name', mk.name), 'model', jsonb_build_object('slug', m.slug, 'name', m.name, 'vclass', m.vclass),
    'year', y.year, 'vclass', y.vclass, 'path', app.vpage_path(y.make_slug, y.model_slug, y.year), 'variants', y.variants, 'sources', y.sources,
    'body_group', app.vpage_body_group(coalesce(y.vclass, m.vclass)),
    'trims', (select coalesce(jsonb_agg(jsonb_build_object('slug', t.slug, 'name', t.name, 'rank', t.rank, 'variant_ids', t.variant_ids,
                'path', app.vpage_path(t.make_slug, t.model_slug, t.year, t.slug)) order by t.rank), '[]'::jsonb)
                from vehicle_catalog_trims t where t.make_slug = y.make_slug and t.model_slug = y.model_slug and t.year = y.year),
    'prev', (select jsonb_build_object('year', p.year, 'variants', p.variants, 'trims', (select coalesce(jsonb_agg(t.name order by t.rank), '[]'::jsonb) from vehicle_catalog_trims t
               where t.make_slug = p.make_slug and t.model_slug = p.model_slug and t.year = p.year))
               from vehicle_catalog_years p where p.make_slug = y.make_slug and p.model_slug = y.model_slug and p.year < y.year order by p.year desc limit 1),
    'next', (select jsonb_build_object('year', n.year) from vehicle_catalog_years n where n.make_slug = y.make_slug and n.model_slug = y.model_slug and n.year > y.year order by n.year limit 1),
    'other_years', app.vpage_year_rows(y.make_slug, y.model_slug),
    'similar_models', app.vpage_similar_models(y.make_slug, y.model_slug, y.year, y.vclass, y.l100_min, y.kwh100_min),
    'inventory', v_inv, 'settings', app.vpage_settings_json(s), 'indexable', v_ok,
    'canonical', case when v_ok then app.vpage_path(y.make_slug, y.model_slug, y.year) else app.vpage_path(y.make_slug, y.model_slug) end,
    'lastmod', greatest(y.updated_at, (v_inv ->> 'lastmod')::timestamptz));
end $$;

-- A trim: the year page's data, the trim's own powertrains, its sibling trims with theirs, the years the trim was sold.
create or replace function app.vehicle_trim_page(p_make text, p_model text, p_year integer, p_trim text) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  t vehicle_catalog_trims;
  y vehicle_catalog_years;
  m vehicle_catalog_models;
  mk vehicle_catalog_makes;
  v_inv jsonb;
  v_ok boolean;
begin
  select * into t from vehicle_catalog_trims x where x.make_slug = lower(btrim(p_make)) and x.model_slug = lower(btrim(p_model)) and x.year = p_year and x.slug = lower(btrim(p_trim));
  if t.slug is null then return null; end if;
  select * into y from vehicle_catalog_years where make_slug = t.make_slug and model_slug = t.model_slug and year = t.year;
  select * into m from vehicle_catalog_models where make_slug = t.make_slug and slug = t.model_slug;
  select * into mk from vehicle_catalog_makes where slug = t.make_slug;
  v_inv := app.vpage_inventory(t.make_slug, t.model_slug, t.year, t.slug, app.vpage_body_group(coalesce(y.vclass, m.vclass)), app.vpage_premium(t.make_slug));
  v_ok := app.vpage_gate('trim', 0, (v_inv ->> 'real_exact')::integer, false, t.year, s);
  return jsonb_build_object(
    'level', 'trim', 'make', jsonb_build_object('slug', mk.slug, 'name', mk.name), 'model', jsonb_build_object('slug', m.slug, 'name', m.name, 'vclass', m.vclass),
    'year', y.year, 'vclass', y.vclass, 'body_group', app.vpage_body_group(coalesce(y.vclass, m.vclass)), 'variants', y.variants, 'sources', y.sources,
    'trim', jsonb_build_object('slug', t.slug, 'name', t.name, 'rank', t.rank, 'variant_ids', t.variant_ids, 'source', t.source),
    'path', app.vpage_path(t.make_slug, t.model_slug, t.year, t.slug),
    'siblings', (select coalesce(jsonb_agg(jsonb_build_object('slug', x.slug, 'name', x.name, 'rank', x.rank, 'variant_ids', x.variant_ids,
                   'path', app.vpage_path(x.make_slug, x.model_slug, x.year, x.slug)) order by x.rank), '[]'::jsonb)
                   from vehicle_catalog_trims x where x.make_slug = t.make_slug and x.model_slug = t.model_slug and x.year = t.year),
    'trim_years', (select coalesce(jsonb_agg(jsonb_build_object('year', x.year, 'path', app.vpage_path(x.make_slug, x.model_slug, x.year, x.slug)) order by x.year), '[]'::jsonb)
                     from vehicle_catalog_trims x where x.make_slug = t.make_slug and x.model_slug = t.model_slug and x.slug = t.slug),
    'prev', (select jsonb_build_object('year', p.year, 'variants', p.variants, 'trim_variant_ids', (select pt.variant_ids from vehicle_catalog_trims pt
               where pt.make_slug = p.make_slug and pt.model_slug = p.model_slug and pt.year = p.year and pt.slug = t.slug))
               from vehicle_catalog_years p where p.make_slug = y.make_slug and p.model_slug = y.model_slug and p.year < y.year order by p.year desc limit 1),
    'other_years', app.vpage_year_rows(y.make_slug, y.model_slug),
    'similar_models', app.vpage_similar_models(y.make_slug, y.model_slug, y.year, y.vclass, y.l100_min, y.kwh100_min),
    'inventory', v_inv, 'settings', app.vpage_settings_json(s), 'indexable', v_ok,
    'canonical', case when v_ok then app.vpage_path(t.make_slug, t.model_slug, t.year, t.slug) else app.vpage_path(t.make_slug, t.model_slug, t.year) end,
    'lastmod', greatest(t.updated_at, y.updated_at, (v_inv ->> 'lastmod')::timestamptz));
end $$;

-- ================================================================ the sitemaps
-- Every page with its level, make, whether it is indexed now and its lastmod (the catalog row's date, or the last
-- change of our matching cars). Set-based: the admin counts and the sitemaps.
create or replace function app.vpage_all(p_make text default null) returns table (level text, make_slug text, path text, lastmod timestamptz, indexable boolean)
language sql stable security definer set search_path = public, app as $$
  with s as (select app.settings() s),
       cars as materialized (select c.make_slug, c.model_slug, c.year, c.trim_slug, c.content_updated_at from app.vpage_cars() c where not c.is_sample),
       ym as (select y.make_slug, y.model_slug, count(*) filter (where y.powertrains > 0) n, max(y.updated_at) upd from vehicle_catalog_years y group by 1, 2)
  select 'make', mk.slug, app.vpage_path(mk.slug), greatest(mk.updated_at, (select max(c.content_updated_at) from cars c where c.make_slug = mk.slug)), true
    from vehicle_catalog_makes mk where p_make is null or mk.slug = p_make
  union all
  select 'model', m.make_slug, app.vpage_path(m.make_slug, m.slug), greatest(m.updated_at, ym.upd, x.upd),
         app.vpage_gate('model', coalesce(ym.n, 0)::integer, coalesce(x.n, 0)::integer, false, null, (select s from s))
    from vehicle_catalog_models m left join ym on ym.make_slug = m.make_slug and ym.model_slug = m.slug
    left join lateral (select count(*) n, max(c.content_updated_at) upd from cars c where c.make_slug = m.make_slug and c.model_slug = m.slug) x on true
   where p_make is null or m.make_slug = p_make
  union all
  select 'year', y.make_slug, app.vpage_path(y.make_slug, y.model_slug, y.year), greatest(y.updated_at, x.upd),
         app.vpage_gate('year', 0, coalesce(x.n, 0)::integer, p.make_slug is not null, y.year, (select s from s))
    from vehicle_catalog_years y left join vehicle_catalog_popular p on p.make_slug = y.make_slug and p.model_slug = y.model_slug
    left join lateral (select count(*) n, max(c.content_updated_at) upd from cars c where c.make_slug = y.make_slug and c.model_slug = y.model_slug and c.year = y.year) x on true
   where p_make is null or y.make_slug = p_make
  union all
  select 'trim', t.make_slug, app.vpage_path(t.make_slug, t.model_slug, t.year, t.slug), greatest(t.updated_at, x.upd),
         app.vpage_gate('trim', 0, coalesce(x.n, 0)::integer, false, t.year, (select s from s))
    from vehicle_catalog_trims t
    left join lateral (select count(*) n, max(c.content_updated_at) upd from cars c where c.make_slug = t.make_slug and c.model_slug = t.model_slug and c.year = t.year and c.trim_slug = t.slug) x on true
   where p_make is null or t.make_slug = p_make
$$;

-- The vehicle sitemaps: one of the makes, then one per make and level ("toyota-models", "toyota-years", "toyota-trims"),
-- each far under 50,000 addresses. Only indexed pages, each with its lastmod.
create or replace function app.vehicle_sitemap_files() returns table (file text, urls bigint, lastmod timestamptz)
language sql stable security definer set search_path = public, app as $$
  select case when level = 'make' then 'makes' else make_slug || '-' || level || 's' end, count(*), max(lastmod)
    from app.vpage_all() where indexable group by 1 order by 1
$$;

create or replace function app.vehicle_sitemap(p_file text) returns table (path text, lastmod timestamptz)
language sql stable security definer set search_path = public, app as $$
  select a.path, a.lastmod from app.vpage_all(case when p_file = 'makes' then null else substring(p_file from '^(.*)-(models|years|trims)$') end) a
   where a.indexable and (case when a.level = 'make' then 'makes' else a.make_slug || '-' || a.level || 's' end) = p_file
   order by a.path
$$;

-- ================================================================ the model page replaces the model hub
-- Every car's model link goes to /cars/<make>/<model> (the catalog's model when it has it). The old /rent/<make-model>
-- answers 301 (web/src/app/rent/[hub]/page.tsx through public.vehicle_hub_path); redirects that pointed at it follow.
create or replace function app.model_hub_path(p_make text, p_model text) returns text
language sql stable security definer set search_path = public, app as $$
  select app.vpage_path(m.make_slug, m.model_slug) from app.vehicle_catalog_match(p_make, p_model, null, null) m
$$;

create or replace function app.vehicle_hub_path(p_hub text) returns text
language sql stable security definer set search_path = public, app as $$
  select coalesce(
    -- a car of the fleet whose old hub this was
    (select app.model_hub_path(v.make, v.model) from vehicles v where app.slugify(v.make || ' ' || v.model) = lower(btrim(p_hub)) order by v.created_at limit 1),
    -- else a catalog model whose make and model make the hub
    (select app.vpage_path(m.make_slug, m.slug) from vehicle_catalog_models m where m.make_slug || '-' || m.slug = lower(btrim(p_hub)) limit 1))
$$;

do $$
declare r record;
begin
  for r in select distinct l.to_path, v.make, v.model from listing_redirects l join vehicles v on l.to_path = '/rent/' || app.slugify(v.make || ' ' || v.model)
            where l.to_path like '/rent/%' loop
    update listing_redirects set to_path = app.model_hub_path(r.make, r.model) where to_path = r.to_path;
  end loop;
end $$;

-- ================================================================ public reads (the pages, on the server)
create or replace function public.vehicle_make_page(p_make text) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.vehicle_make_page(p_make) $$;
create or replace function public.vehicle_model_page(p_make text, p_model text) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.vehicle_model_page(p_make, p_model) $$;
create or replace function public.vehicle_year_page(p_make text, p_model text, p_year integer) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.vehicle_year_page(p_make, p_model, p_year) $$;
create or replace function public.vehicle_trim_page(p_make text, p_model text, p_year integer, p_trim text) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.vehicle_trim_page(p_make, p_model, p_year, p_trim) $$;
create or replace function public.vehicle_sitemap_files() returns jsonb
language sql stable security invoker set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('file', f.file, 'urls', f.urls, 'lastmod', f.lastmod) order by f.file), '[]'::jsonb) from app.vehicle_sitemap_files() f
$$;
create or replace function public.vehicle_sitemap(p_file text) returns jsonb
language sql stable security invoker set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('path', s.path, 'lastmod', s.lastmod) order by s.path), '[]'::jsonb) from app.vehicle_sitemap(p_file) s
$$;
-- The makes for the fleet page's "Browse by make" (every make page is linked from /cars).
create or replace function public.vehicle_makes() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('slug', mk.slug, 'name', mk.name, 'path', app.vpage_path(mk.slug),
           'models', (select count(*) from vehicle_catalog_models m where m.make_slug = mk.slug)) order by mk.name), '[]'::jsonb)
    from vehicle_catalog_makes mk
$$;
create or replace function public.vehicle_hub_path(p_hub text) returns text
language sql stable security invoker set search_path = public, app as $$ select app.vehicle_hub_path(p_hub) $$;

-- ================================================================ 5. Admin > Settings > Vehicle pages
create or replace function app.vpage_admin(p_user uuid, p_call text, p_name text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_lines jsonb;
  v_make text; v_model text;
  n integer;
begin
  perform app.assert_admin(p_user);
  case p_name
  when 'vehicle_pages' then
    return jsonb_build_object(
      'settings', app.vpage_settings_json(app.settings()),
      'counts', (select coalesce(jsonb_object_agg(level, jsonb_build_object('total', total, 'indexed', indexed)), '{}'::jsonb)
                   from (select level, count(*) total, count(*) filter (where indexable) indexed from app.vpage_all() group by level) c),
      'sitemaps', (select count(*) from app.vehicle_sitemap_files()),
      'makes', (select count(*) from vehicle_catalog_makes),
      'last_import', (select to_jsonb(i) - 'meta' || jsonb_build_object('stats', i.meta -> 'stats', 'run_url', i.meta ->> 'run_url')
                        from vehicle_catalog_imports i order by i.started_at desc limit 1),
      'last_done', (select max(finished_at) from vehicle_catalog_imports where status = 'done'),
      'requested', (select max(requested_at) from vehicle_catalog_import_requests where import_id is null),
      'popular', (select coalesce(jsonb_agg(jsonb_build_object('make', p.make_slug, 'model', p.model_slug,
                    'name', coalesce(mk.name || ' ' || m.name, p.make_slug || ' ' || p.model_slug), 'in_catalog', m.slug is not null) order by p.sort, p.make_slug, p.model_slug), '[]'::jsonb)
                    from vehicle_catalog_popular p left join vehicle_catalog_models m on m.make_slug = p.make_slug and m.slug = p.model_slug
                    left join vehicle_catalog_makes mk on mk.slug = p.make_slug),
      'trim_models', (select coalesce(jsonb_agg(x order by x ->> 'name'), '[]'::jsonb) from (
                        select jsonb_build_object('make', l.make_slug, 'model', l.model_slug, 'name', coalesce(min(mk.name) || ' ' || min(m.name), l.make_slug || ' ' || l.model_slug),
                               'source', case when bool_or(l.source = 'admin') then 'admin' else 'seed' end,
                               'lines', string_agg(case when l.from_year = l.to_year then l.from_year::text else l.from_year || '-' || l.to_year end || ': ' || array_to_string(l.trims, ', '),
                                                   E'\n' order by l.sort, l.id) filter (where l.source = 'admin' or not exists (
                                                     select 1 from vehicle_catalog_trim_lines a where a.make_slug = l.make_slug and a.model_slug = l.model_slug and a.source = 'admin'))) x
                          from vehicle_catalog_trim_lines l left join vehicle_catalog_models m on m.make_slug = l.make_slug and m.slug = l.model_slug
                          left join vehicle_catalog_makes mk on mk.slug = l.make_slug group by l.make_slug, l.model_slug) q),
      'models', (select count(*) from vehicle_catalog_models));
  when 'vehicle_pages_import' then
    insert into vehicle_catalog_import_requests (requested_by) values (p_user);
    return jsonb_build_object('ok', true);
  when 'vehicle_pages_popular' then
    -- the whole list, one "Make Model" (or "make | model") per line, most popular first
    create temporary table if not exists vpage_pop (make_slug text, model_slug text, sort integer) on commit drop;
    truncate vpage_pop;
    insert into vpage_pop
    select x.make_slug, x.model_slug, min(x.ord)::integer from (
      select ord, coalesce((select mk.slug from vehicle_catalog_makes mk where app.slugify(line) = mk.slug or app.slugify(line) like mk.slug || '-%' order by length(mk.slug) desc limit 1), '') make_slug, line
        from unnest(string_to_array(replace(coalesce(p ->> 'lines', ''), '|', ' '), E'\n')) with ordinality u(line, ord) where btrim(line) <> '') y
    cross join lateral (select y.make_slug, coalesce((select m.slug from vehicle_catalog_models m where m.make_slug = y.make_slug
                          and (m.slug = substr(app.slugify(y.line), length(y.make_slug) + 2) or m.key = app.vehicle_model_key(substr(app.slugify(y.line), length(y.make_slug) + 2))
                               or app.vehicle_model_key(substr(app.slugify(y.line), length(y.make_slug) + 2)) = any (m.aliases)) limit 1), '') model_slug, y.ord) x
     where x.make_slug <> '' and x.model_slug <> ''
     group by x.make_slug, x.model_slug;
    insert into vehicle_catalog_popular_removed (make_slug, model_slug, removed_by)
    select p0.make_slug, p0.model_slug, p_user from vehicle_catalog_popular p0 where not exists (select 1 from vpage_pop n where (n.make_slug, n.model_slug) = (p0.make_slug, p0.model_slug))
    on conflict do nothing;
    delete from vehicle_catalog_popular_removed r where exists (select 1 from vpage_pop n where (n.make_slug, n.model_slug) = (r.make_slug, r.model_slug));
    delete from vehicle_catalog_popular p0 where not exists (select 1 from vpage_pop n where (n.make_slug, n.model_slug) = (p0.make_slug, p0.model_slug));
    insert into vehicle_catalog_popular (make_slug, model_slug, sort, added_by) select make_slug, model_slug, sort, p_user from vpage_pop
    on conflict (make_slug, model_slug) do update set sort = excluded.sort;
    select count(*) into n from vpage_pop;
    return jsonb_build_object('ok', true, 'count', n,
      'unknown', (select count(*) from unnest(string_to_array(coalesce(p ->> 'lines', ''), E'\n')) l where btrim(l) <> '') - n);
  when 'vehicle_pages_trims' then
    -- one model's trim lines, "2020-2021: Comfortline, Highline" per line; empty puts the list's lines back
    v_make := p ->> 'make'; v_model := p ->> 'model';
    if not exists (select 1 from vehicle_catalog_models where make_slug = v_make and slug = v_model) then
      raise exception 'Choose a model of the catalog' using errcode = '22023';
    end if;
    if exists (select 1 from unnest(string_to_array(coalesce(p ->> 'lines', ''), E'\n')) l
                where btrim(l) <> '' and btrim(l) !~ '^\d{4}(\s*-\s*\d{4})?\s*:\s*.+$') then
      raise exception 'Write each line as "2020-2021: Comfortline, Highline"' using errcode = '22023';
    end if;
    delete from vehicle_catalog_trim_lines where make_slug = v_make and model_slug = v_model and source = 'admin';
    insert into vehicle_catalog_trim_lines (make_slug, model_slug, from_year, to_year, trims, source, sort, updated_by)
    select v_make, v_model, (m[1])::smallint, coalesce(m[2], m[1])::smallint,
           array(select btrim(x) from unnest(string_to_array(m[3], ',')) x where btrim(x) <> ''), 'admin', ord::integer, p_user
      from unnest(string_to_array(coalesce(p ->> 'lines', ''), E'\n')) with ordinality u(line, ord)
      cross join lateral regexp_match(btrim(line), '^(\d{4})(?:\s*-\s*(\d{4}))?\s*:\s*(.+)$') m
     where btrim(line) <> '';
    n := app.vehicle_catalog_build_trims(v_make, v_model);
    return jsonb_build_object('ok', true, 'trims', n);
  else raise exception 'Unknown action %', p_name using errcode = '22023';
  end case;
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0092;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if (p_call = 'admin_read' and p_name = 'vehicle_pages')
     or (p_call = 'admin_do' and p_name in ('vehicle_pages_import', 'vehicle_pages_popular', 'vehicle_pages_trims')) then
    perform app.door_begin(p_user, p_aal);
    return app.vpage_admin(p_user, p_call, p_name, coalesce(p, '{}'::jsonb));
  end if;
  return app.door_pre0092(p_user, p_aal, p_call, p_name, p);
end $$;

-- ================================================================ privileges
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and (p.proname like 'vehicle\_catalog\_%' or p.proname like 'vpage\_%' or p.proname in (
             'vehicle_trim_slug', 'vehicle_model_key', 'vehicle_make_slug', 'vehicle_trim_variants', 'vehicle_make_page', 'vehicle_model_page',
             'vehicle_year_page', 'vehicle_trim_page', 'vehicle_sitemap_files', 'vehicle_sitemap', 'vehicle_hub_path', 'door_pre0092', 'door'))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
-- the public pages read as anon (the server's anonymous calls, like public.fleet); the helpers they and the fleet use
grant execute on function app.vehicle_make_page(text), app.vehicle_model_page(text, text), app.vehicle_year_page(text, text, integer),
  app.vehicle_trim_page(text, text, integer, text), app.vehicle_sitemap_files(), app.vehicle_sitemap(text), app.vehicle_hub_path(text),
  app.model_hub_path(text, text), app.vehicle_catalog_match(text, text, integer, text), app.vpage_path(text, text, integer, text),
  app.vehicle_make_slug(text), app.vehicle_model_key(text), app.vehicle_trim_slug(text), app.vpage_token_prefix(text, text)
  to anon, authenticated;
revoke all on function public.vehicle_makes(), public.vehicle_make_page(text), public.vehicle_model_page(text, text), public.vehicle_year_page(text, text, integer),
  public.vehicle_trim_page(text, text, integer, text), public.vehicle_sitemap_files(), public.vehicle_sitemap(text), public.vehicle_hub_path(text) from public;
grant execute on function public.vehicle_makes(), public.vehicle_make_page(text), public.vehicle_model_page(text, text), public.vehicle_year_page(text, text, integer),
  public.vehicle_trim_page(text, text, integer, text), public.vehicle_sitemap_files(), public.vehicle_sitemap(text), public.vehicle_hub_path(text)
  to anon, authenticated, service_role;

-- ================================================================ the guides (Admin: Vehicle pages; customer service: A request from a vehicle page)
-- GUIDES VEHICLE PAGES START (generated by supabase/seed/vehicle_pages_gen_guides.mjs from docs/guides/content; do not edit by hand)
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

## Search engines and business listings

**Settings** > **All settings**, then Site settings.

1. Search engines: paste the Google Search Console value (HTML tag) or the file name (HTML file), and the Bing value. The steps are on the card.
2. Business name, address and phone: the exact text for every listing, and the description and categories.
3. Business listings: press **Copy** beside each line and paste it into Google Business Profile, Bing Places, Apple Business Connect, Yelp, Yellow Pages and Facebook. Tick each one when it is done.

> Good to know: Changed pages are sent to IndexNow (Bing and the other engines that use it) by themselves. Google reads the sitemap: submit carmacars.ca/sitemap.xml once in Search Console.
', 'Search: car pages, landing pages and guides', 'Car copy written by itself, landing pages, guides, search engines, business listings and IndexNow.',
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

**Settings** > **Vehicle pages**. A page for every make, model, model year and Canadian trim, at carmacars.ca/cars/make/model/year/trim, with our cars below it.

1. Pages: how many make, model, year and trim pages there are and how many are in search. Every page is in search by default; nothing needs setting up.
2. Each page is built from data: the EPA fuel-use ratings in litres per 100 km, the cost to drive 100 km at the gas or electricity price set here, what changed from the year before, how a trim differs from the others, similar models, and the rental questions from the program settings.
3. Below the facts: our cars of that exact year, model and trim, then the same model in other years, then similar cars free now, and Request it, which sends an enquiry to Bookings > Leads.
4. Settings: **Index every page** (the default) or **Only pages that pass the rules**: makes, models with 2 or more years of data, years with one of our cars or of a popular model from 2015, trims with one of our cars. The others stay visible but out of search. Also the gas, premium and electricity prices, and how often the catalog is imported (every 30 days).
5. Canadian trims: open a model and type one line per run of years, entry trim first: 2020-2021: Comfortline, Highline, Sportline, Execline. Your lines are kept by every import; empty them to go back to the CarmaCars list. **Add trims for another model** adds a model that has none.
6. Catalog import: the last import and its counts. **Import now** asks for a new one; it runs at the next daily check, at 07:17 UTC.

> Good to know: A car joins its pages by itself once it is on the site: its make, model, year and trim are read from the car. A trim that names several (S / SE / R-Line) leaves the car on the year page only; set the car''s trim to one Canadian name to put it on the trim page.

## Search engines and business listings

**Settings** > **All settings**, then Site settings.

1. Search engines: paste the Google Search Console value (HTML tag) or the file name (HTML file), and the Bing value. The steps are on the card.
2. Business name, address and phone: the exact text for every listing, and the description and categories.
3. Business listings: press **Copy** beside each line and paste it into Google Business Profile, Bing Places, Apple Business Connect, Yelp, Yellow Pages and Facebook. Tick each one when it is done.

> Good to know: Changed pages are sent to IndexNow (Bing and the other engines that use it) by themselves. Google reads the sitemap: submit carmacars.ca/sitemap.xml once in Search Console.
',
  '<p class="gd-p">The text of every car page, the landing pages for each area and way of renting, and the guides are written by Workers AI from the facts in the database, checked and published by themselves. Nobody has to type or review anything. You can still change any line; what you change is kept.</p><section class="gd-task" id="search-car-pages-landing-pages-and-guides-the-copy-of-a-car" data-gd-task><h2 class="gd-h2">The copy of a car</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Vehicles</b>, then the car, then its Listing tab. The same card is on the listing review.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The card says who wrote the text: a plain copy from the car&#39;s facts while the written copy is prepared (usually minutes), then Workers AI.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Every field is shown: search title and description, heading, introduction, highlights, good for, what&#39;s included, pickup and delivery, requirements, questions and the photo descriptions.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">To change a field press <b class="gd-ui">Change</b>, then <b class="gd-ui">Save and lock</b>. A locked field is kept by every new version. <b class="gd-ui">Unlock</b> lets it be written again.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Write again</b> asks for a new version now. A new version is also written by itself when the car&#39;s facts change: its rates, specs, area or photos.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>The checks refuse long dashes, sales words, the numbered company, any number that is not in the car&#39;s facts (a price, a seat count) and equipment the facts do not list. A version that fails is asked again with the problems named; if it still fails, the page keeps its current text and it is tried again later.</div></aside></section><section class="gd-task" id="search-car-pages-landing-pages-and-guides-landing-pages-and-guides" data-gd-task><h2 class="gd-h2">Landing pages and guides</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">All settings</b>, then Search.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Today: the Workers AI used for search copy and in all, and IndexNow (addresses waiting and sent).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Car copy: every real car, who wrote its text, and whether its facts changed since.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Landing pages: each place and way of renting, whether it is in search, its cars and who wrote it. A page for a way of renting (monthly, SUV) goes into search once enough real cars match it (Program settings).</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Open <b class="gd-ui">Edit</b> on a page or a guide to change its text. Edited fields are locked. <b class="gd-ui">Write again</b> asks for a new version; on a guide, the brief says what it must cover.</div></li></ol></div></section><section class="gd-task" id="search-car-pages-landing-pages-and-guides-vehicle-pages" data-gd-task><h2 class="gd-h2">Vehicle pages</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Vehicle pages</b>. A page for every make, model, model year and Canadian trim, at carmacars.ca/cars/make/model/year/trim, with our cars below it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Pages: how many make, model, year and trim pages there are and how many are in search. Every page is in search by default; nothing needs setting up.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each page is built from data: the EPA fuel-use ratings in litres per 100 km, the cost to drive 100 km at the gas or electricity price set here, what changed from the year before, how a trim differs from the others, similar models, and the rental questions from the program settings.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Below the facts: our cars of that exact year, model and trim, then the same model in other years, then similar cars free now, and Request it, which sends an enquiry to Bookings &gt; Leads.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Settings: <b class="gd-ui">Index every page</b> (the default) or <b class="gd-ui">Only pages that pass the rules</b>: makes, models with 2 or more years of data, years with one of our cars or of a popular model from 2015, trims with one of our cars. The others stay visible but out of search. Also the gas, premium and electricity prices, and how often the catalog is imported (every 30 days).</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Canadian trims: open a model and type one line per run of years, entry trim first: 2020-2021: Comfortline, Highline, Sportline, Execline. Your lines are kept by every import; empty them to go back to the CarmaCars list. <b class="gd-ui">Add trims for another model</b> adds a model that has none.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Catalog import: the last import and its counts. <b class="gd-ui">Import now</b> asks for a new one; it runs at the next daily check, at 07:17 UTC.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A car joins its pages by itself once it is on the site: its make, model, year and trim are read from the car. A trim that names several (S / SE / R-Line) leaves the car on the year page only; set the car&#39;s trim to one Canadian name to put it on the trim page.</div></aside></section><section class="gd-task" id="search-car-pages-landing-pages-and-guides-search-engines-and-business-listings" data-gd-task><h2 class="gd-h2">Search engines and business listings</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">All settings</b>, then Site settings.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Search engines: paste the Google Search Console value (HTML tag) or the file name (HTML file), and the Bing value. The steps are on the card.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Business name, address and phone: the exact text for every listing, and the description and categories.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Business listings: press <b class="gd-ui">Copy</b> beside each line and paste it into Google Business Profile, Bing Places, Apple Business Connect, Yelp, Yellow Pages and Facebook. Tick each one when it is done.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Changed pages are sent to IndexNow (Bing and the other engines that use it) by themselves. Google reads the sitemap: submit carmacars.ca/sitemap.xml once in Search Console.</div></aside></section>');
select app.guide_release_section('va', 'customer-service', 'chapter', 'your-workday', 'You answer requests with offers, quote callers, reply to renters, look renters up, and review owner forms. You are often the renter''s first person.

Your rail: Queue, Today, Requests, New quote, Renter messages, Find a renter, Calendar, Listings, Similar cars, Owners and enquiries, Owner forms and Scorecard.

## Answer a request

1. Open **Requests**. Filter by New, Waiting on the renter, Pushed back, Offer out or Offer expired.
2. Waiting shows how long the renter has waited. Open the booking number.

![](/guides/img/va-cs-03-requests-desktop-b3c66d25.jpg "desktop; size: 1440 640; address: carmacars.ca/va/requests; pins: 1 27.1 17.5, 2 52.8 32.8")

3. On the Review tab, check the request: the car is free, the renter, the places.
4. Press **Adjust the booking** to change the car, dates, places, price or extras, then **Save changes**.
5. Add a message and press **Send the offer**. Within your limit you can also use **Approve (within my limit)** or **Approve and send the pay link**.
6. Can''t do it? **Decline** with Reason and any alternative. Need to know more? **Ask the renter**.

![](/guides/img/va-cs-04-booking-review-desktop-52c68a73.jpg "desktop; size: 1440 1000; address: carmacars.ca/va/bookings/CC-10056?tab=review; pins: 3 69.4 24.0, 4 95.8 98.0")

> Tip: Reply within 5 minutes: send the offer, or ask the renter what you need. That is the "First reply in opening hours" measure on your scorecard. Requests waiting longer show in red.

## An enquiry on an example car

Some cars on the site are marked "Example car": samples that show the kind of cars we rent. A request on one is an enquiry, never a booking.

1. The task Suggest a similar real car comes to To do with the enquiry number (EQ-1001 and up), the car asked for, the dates and the contact.
2. Find a real car of the same kind and price that is free for those dates, and make a **New quote** for it.
3. Call or email the person with the car and the price, then mark the task done.

> Tip: Reply within the first reply target, as for any request. Never offer the example car itself: it does not exist.

## New quote for a caller

1. Open **New quote**. Choose the Car, the Pickup and Return (at least 2 hours from now).
2. Choose how the lead came in, then the caller''s Full legal name, Email, Mobile and Date of birth.
3. Set the Licence class and Damage cover, and note places, extras and what they asked.
4. Press **Create the request**. It opens like any request; send the offer from there.

![](/guides/img/va-cs-05-new-quote-desktop-4e386b1c.jpg "desktop; size: 1220 1260; address: carmacars.ca/va/quotes/new; pins: 1 72.1 15.6, 2 72.1 41.7, 3 72.1 72.7, 4 63.9 85.5")

## Renter messages and Find a renter

1. **Renter messages** lists the latest messages with their booking. Open the booking to reply, then press **Send**.
2. **Find a renter**: search by name, email, phone or booking number.
3. To open a renter''s private details, press **Open with a reason**. The reason is kept in the access log.

![](/guides/img/va-cs-06-messages-desktop-3441fa91.jpg "desktop; size: 1440 260; address: carmacars.ca/va/messages; pins: 1 32.6 48.5")

## Add a car for an owner

Open **Owners** > **Add a car for an owner** (fleet: under Cars). You enter everything for the owner; they never fill in the application.

1. The owner: find them by name, email or phone, or choose New owner and enter the name, email, phone and address.
2. The car: type the VIN and press Decode, then the details. Upload the ownership permit, the insurance slip and the lender''s information if you have them. Photos are optional.
3. Terms and first invoice: what was agreed with the owner, to the cent. An Admin checks them before anything is sent.
4. Who sourced the owner: Entered for CarmaCars, or I sourced this owner. How the owner signs: by email, or on paper.
5. Press **Add the car and send to an Admin**. The application waits in the Admin''s Applications, marked Entered by staff with your name. When the Admin approves, the owner gets one email to review and sign.

## Owner forms (Forms C and D)

1. Open **Owner forms**. Each row is a scan an owner uploaded, with the witnesses and the status.
2. Press Open to read the scan. Check every page is there and signed, with each witness''s signature and name.
3. Press **Approve**, or **Send back** with What to fix (the owner reads this).

![](/guides/img/va-cs-08-owner-forms-desktop-eceaee0b.jpg "desktop; size: 1440 300; address: carmacars.ca/va/owner-forms; pins: 2 68.6 36.7, 3 76.7 36.7")

## A rental agreement signed on paper

1. Open the booking. Under Signed on paper, press **Record paper signature**.
2. Choose the Rental agreement, or the booking change the renter signed.
3. Check Signed by and Date signed, and upload the scan of every signed page.
4. Press **Record signature**. It counts as signed, and the renter is not asked to sign again.

## A change to a confirmed booking

On a booking''s Changes tab you can propose new dates, times or another car, as an Admin does: set the change, write the reason, press **Preview the price**, then **Send to the renter**. The renter has 48 hours to accept and sign the amendment. You also send a new signing link to an additional driver from the booking screen.

## A late return

A booking past its return time shows the late return panel. Work it in order:

| Button | When |
| --- | --- |
| **Log a call** | Record each call to the renter and what they said. |
| **Send T13** | The first late notice email. |
| **Send T14 (final notice)** | The final notice. |
| **Request disable** | Ask an Admin to approve disabling the car. |
| **Open an incident** | When the car is not coming back as planned. |
', 'Customer service', 'Requests and offers, new quotes, renter messages, find a renter, owner forms, late returns.',
  'You answer requests with offers, quote callers, reply to renters, look renters up, and review owner forms. You are often the renter''s first person.

Your rail: Queue, Today, Requests, New quote, Renter messages, Find a renter, Calendar, Listings, Similar cars, Owners and enquiries, Owner forms and Scorecard.

## Answer a request

1. Open **Requests**. Filter by New, Waiting on the renter, Pushed back, Offer out or Offer expired.
2. Waiting shows how long the renter has waited. Open the booking number.

![](/guides/img/va-cs-03-requests-desktop-b3c66d25.jpg "desktop; size: 1440 640; address: carmacars.ca/va/requests; pins: 1 27.1 17.5, 2 52.8 32.8")

3. On the Review tab, check the request: the car is free, the renter, the places.
4. Press **Adjust the booking** to change the car, dates, places, price or extras, then **Save changes**.
5. Add a message and press **Send the offer**. Within your limit you can also use **Approve (within my limit)** or **Approve and send the pay link**.
6. Can''t do it? **Decline** with Reason and any alternative. Need to know more? **Ask the renter**.

![](/guides/img/va-cs-04-booking-review-desktop-52c68a73.jpg "desktop; size: 1440 1000; address: carmacars.ca/va/bookings/CC-10056?tab=review; pins: 3 69.4 24.0, 4 95.8 98.0")

> Tip: Reply within 5 minutes: send the offer, or ask the renter what you need. That is the "First reply in opening hours" measure on your scorecard. Requests waiting longer show in red.

## An enquiry on an example car

Some cars on the site are marked "Example car": samples that show the kind of cars we rent. A request on one is an enquiry, never a booking.

1. The task Suggest a similar real car comes to To do with the enquiry number (EQ-1001 and up), the car asked for, the dates and the contact.
2. Find a real car of the same kind and price that is free for those dates, and make a **New quote** for it.
3. Call or email the person with the car and the price, then mark the task done.

> Tip: Reply within the first reply target, as for any request. Never offer the example car itself: it does not exist.

## A request from a vehicle page

Every make, model, year and trim page (carmacars.ca/cars/toyota/rav4/2023/xle, for example) has Request it, for the exact car the person wants.

1. The request arrives as an enquiry with the car named in the message ("About the car: 2023 Toyota RAV4 XLE") and an Enquiry task in To do.
2. If we have that car, or one close to it, free for their dates, make a **New quote** for it. If not, suggest the nearest car of the same kind and price.
3. Reply by email or phone, then mark the task done.

> Tip: The pages say only what the data says: EPA fuel use, the Canadian trims and our own cars. Never promise equipment the page does not list.

## New quote for a caller

1. Open **New quote**. Choose the Car, the Pickup and Return (at least 2 hours from now).
2. Choose how the lead came in, then the caller''s Full legal name, Email, Mobile and Date of birth.
3. Set the Licence class and Damage cover, and note places, extras and what they asked.
4. Press **Create the request**. It opens like any request; send the offer from there.

![](/guides/img/va-cs-05-new-quote-desktop-4e386b1c.jpg "desktop; size: 1220 1260; address: carmacars.ca/va/quotes/new; pins: 1 72.1 15.6, 2 72.1 41.7, 3 72.1 72.7, 4 63.9 85.5")

## Renter messages and Find a renter

1. **Renter messages** lists the latest messages with their booking. Open the booking to reply, then press **Send**.
2. **Find a renter**: search by name, email, phone or booking number.
3. To open a renter''s private details, press **Open with a reason**. The reason is kept in the access log.

![](/guides/img/va-cs-06-messages-desktop-3441fa91.jpg "desktop; size: 1440 260; address: carmacars.ca/va/messages; pins: 1 32.6 48.5")

## Add a car for an owner

Open **Owners** > **Add a car for an owner** (fleet: under Cars). You enter everything for the owner; they never fill in the application.

1. The owner: find them by name, email or phone, or choose New owner and enter the name, email, phone and address.
2. The car: type the VIN and press Decode, then the details. Upload the ownership permit, the insurance slip and the lender''s information if you have them. Photos are optional.
3. Terms and first invoice: what was agreed with the owner, to the cent. An Admin checks them before anything is sent.
4. Who sourced the owner: Entered for CarmaCars, or I sourced this owner. How the owner signs: by email, or on paper.
5. Press **Add the car and send to an Admin**. The application waits in the Admin''s Applications, marked Entered by staff with your name. When the Admin approves, the owner gets one email to review and sign.

## Owner forms (Forms C and D)

1. Open **Owner forms**. Each row is a scan an owner uploaded, with the witnesses and the status.
2. Press Open to read the scan. Check every page is there and signed, with each witness''s signature and name.
3. Press **Approve**, or **Send back** with What to fix (the owner reads this).

![](/guides/img/va-cs-08-owner-forms-desktop-eceaee0b.jpg "desktop; size: 1440 300; address: carmacars.ca/va/owner-forms; pins: 2 68.6 36.7, 3 76.7 36.7")

## A rental agreement signed on paper

1. Open the booking. Under Signed on paper, press **Record paper signature**.
2. Choose the Rental agreement, or the booking change the renter signed.
3. Check Signed by and Date signed, and upload the scan of every signed page.
4. Press **Record signature**. It counts as signed, and the renter is not asked to sign again.

## A change to a confirmed booking

On a booking''s Changes tab you can propose new dates, times or another car, as an Admin does: set the change, write the reason, press **Preview the price**, then **Send to the renter**. The renter has 48 hours to accept and sign the amendment. You also send a new signing link to an additional driver from the booking screen.

## A late return

A booking past its return time shows the late return panel. Work it in order:

| Button | When |
| --- | --- |
| **Log a call** | Record each call to the renter and what they said. |
| **Send T13** | The first late notice email. |
| **Send T14 (final notice)** | The final notice. |
| **Request disable** | Ask an Admin to approve disabling the car. |
| **Open an incident** | When the car is not coming back as planned. |
',
  '<p class="gd-p">You answer requests with offers, quote callers, reply to renters, look renters up, and review owner forms. You are often the renter&#39;s first person.</p><p class="gd-p">Your rail: Queue, Today, Requests, New quote, Renter messages, Find a renter, Calendar, Listings, Similar cars, Owners and enquiries, Owner forms and Scorecard.</p><section class="gd-task" id="customer-service-answer-a-request" data-gd-task><h2 class="gd-h2">Answer a request</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Requests</b>. Filter by New, Waiting on the renter, Pushed back, Offer out or Offer expired.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Waiting shows how long the renter has waited. Open the booking number.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/requests</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/640"><img src="/guides/img/va-cs-03-requests-desktop-b3c66d25.jpg" alt="" loading="lazy" decoding="async" width="1440" height="640"><span class="gd-pin" style="left:27.1%;top:17.5%" aria-hidden="true">1</span><span class="gd-pin" style="left:52.8%;top:32.8%" aria-hidden="true">2</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="3"><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">On the Review tab, check the request: the car is free, the renter, the places.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Adjust the booking</b> to change the car, dates, places, price or extras, then <b class="gd-ui">Save changes</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Add a message and press <b class="gd-ui">Send the offer</b>. Within your limit you can also use <b class="gd-ui">Approve (within my limit)</b> or <b class="gd-ui">Approve and send the pay link</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Can&#39;t do it? <b class="gd-ui">Decline</b> with Reason and any alternative. Need to know more? <b class="gd-ui">Ask the renter</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/bookings/CC-10056?tab=review</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1000"><img src="/guides/img/va-cs-04-booking-review-desktop-52c68a73.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1000"><span class="gd-pin" style="left:69.4%;top:24%" aria-hidden="true">3</span><span class="gd-pin" style="left:95.8%;top:98%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Reply within 5 minutes: send the offer, or ask the renter what you need. That is the &quot;First reply in opening hours&quot; measure on your scorecard. Requests waiting longer show in red.</div></aside></section><section class="gd-task" id="customer-service-an-enquiry-on-an-example-car" data-gd-task><h2 class="gd-h2">An enquiry on an example car</h2><p class="gd-p">Some cars on the site are marked &quot;Example car&quot;: samples that show the kind of cars we rent. A request on one is an enquiry, never a booking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The task Suggest a similar real car comes to To do with the enquiry number (EQ-1001 and up), the car asked for, the dates and the contact.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Find a real car of the same kind and price that is free for those dates, and make a <b class="gd-ui">New quote</b> for it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Call or email the person with the car and the price, then mark the task done.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Reply within the first reply target, as for any request. Never offer the example car itself: it does not exist.</div></aside></section><section class="gd-task" id="customer-service-a-request-from-a-vehicle-page" data-gd-task><h2 class="gd-h2">A request from a vehicle page</h2><p class="gd-p">Every make, model, year and trim page (carmacars.ca/cars/toyota/rav4/2023/xle, for example) has Request it, for the exact car the person wants.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The request arrives as an enquiry with the car named in the message (&quot;About the car: 2023 Toyota RAV4 XLE&quot;) and an Enquiry task in To do.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">If we have that car, or one close to it, free for their dates, make a <b class="gd-ui">New quote</b> for it. If not, suggest the nearest car of the same kind and price.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Reply by email or phone, then mark the task done.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The pages say only what the data says: EPA fuel use, the Canadian trims and our own cars. Never promise equipment the page does not list.</div></aside></section><section class="gd-task" id="customer-service-new-quote-for-a-caller" data-gd-task><h2 class="gd-h2">New quote for a caller</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">New quote</b>. Choose the Car, the Pickup and Return (at least 2 hours from now).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose how the lead came in, then the caller&#39;s Full legal name, Email, Mobile and Date of birth.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Set the Licence class and Damage cover, and note places, extras and what they asked.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Create the request</b>. It opens like any request; send the offer from there.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/quotes/new</span></div><div class="gd-imgwrap" style="aspect-ratio:1220/1260"><img src="/guides/img/va-cs-05-new-quote-desktop-4e386b1c.jpg" alt="" loading="lazy" decoding="async" width="1220" height="1260"><span class="gd-pin" style="left:72.1%;top:15.6%" aria-hidden="true">1</span><span class="gd-pin" style="left:72.1%;top:41.7%" aria-hidden="true">2</span><span class="gd-pin" style="left:72.1%;top:72.7%" aria-hidden="true">3</span><span class="gd-pin" style="left:63.9%;top:85.5%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="customer-service-renter-messages-and-find-a-renter" data-gd-task><h2 class="gd-h2">Renter messages and Find a renter</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Renter messages</b> lists the latest messages with their booking. Open the booking to reply, then press <b class="gd-ui">Send</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Find a renter</b>: search by name, email, phone or booking number.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">To open a renter&#39;s private details, press <b class="gd-ui">Open with a reason</b>. The reason is kept in the access log.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/messages</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/260"><img src="/guides/img/va-cs-06-messages-desktop-3441fa91.jpg" alt="" loading="lazy" decoding="async" width="1440" height="260"><span class="gd-pin" style="left:32.6%;top:48.5%" aria-hidden="true">1</span></div></div></figure></div></section><section class="gd-task" id="customer-service-add-a-car-for-an-owner" data-gd-task><h2 class="gd-h2">Add a car for an owner</h2><p class="gd-p">Open <b class="gd-ui">Owners</b> &gt; <b class="gd-ui">Add a car for an owner</b> (fleet: under Cars). You enter everything for the owner; they never fill in the application.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The owner: find them by name, email or phone, or choose New owner and enter the name, email, phone and address.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The car: type the VIN and press Decode, then the details. Upload the ownership permit, the insurance slip and the lender&#39;s information if you have them. Photos are optional.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Terms and first invoice: what was agreed with the owner, to the cent. An Admin checks them before anything is sent.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Who sourced the owner: Entered for CarmaCars, or I sourced this owner. How the owner signs: by email, or on paper.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press <b class="gd-ui">Add the car and send to an Admin</b>. The application waits in the Admin&#39;s Applications, marked Entered by staff with your name. When the Admin approves, the owner gets one email to review and sign.</div></li></ol></div></section><section class="gd-task" id="customer-service-owner-forms-forms-c-and-d" data-gd-task><h2 class="gd-h2">Owner forms (Forms C and D)</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Owner forms</b>. Each row is a scan an owner uploaded, with the witnesses and the status.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press Open to read the scan. Check every page is there and signed, with each witness&#39;s signature and name.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Approve</b>, or <b class="gd-ui">Send back</b> with What to fix (the owner reads this).</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/owner-forms</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/300"><img src="/guides/img/va-cs-08-owner-forms-desktop-eceaee0b.jpg" alt="" loading="lazy" decoding="async" width="1440" height="300"><span class="gd-pin" style="left:68.6%;top:36.7%" aria-hidden="true">2</span><span class="gd-pin" style="left:76.7%;top:36.7%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="customer-service-a-rental-agreement-signed-on-paper" data-gd-task><h2 class="gd-h2">A rental agreement signed on paper</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the booking. Under Signed on paper, press <b class="gd-ui">Record paper signature</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose the Rental agreement, or the booking change the renter signed.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Check Signed by and Date signed, and upload the scan of every signed page.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Record signature</b>. It counts as signed, and the renter is not asked to sign again.</div></li></ol></div></section><section class="gd-task" id="customer-service-a-change-to-a-confirmed-booking" data-gd-task><h2 class="gd-h2">A change to a confirmed booking</h2><p class="gd-p">On a booking&#39;s Changes tab you can propose new dates, times or another car, as an Admin does: set the change, write the reason, press <b class="gd-ui">Preview the price</b>, then <b class="gd-ui">Send to the renter</b>. The renter has 48 hours to accept and sign the amendment. You also send a new signing link to an additional driver from the booking screen.</p></section><section class="gd-task" id="customer-service-a-late-return" data-gd-task><h2 class="gd-h2">A late return</h2><p class="gd-p">A booking past its return time shows the late return panel. Work it in order:</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Button</th><th scope="col">When</th></tr></thead><tbody><tr><td><b class="gd-ui">Log a call</b></td><td>Record each call to the renter and what they said.</td></tr><tr><td><b class="gd-ui">Send T13</b></td><td>The first late notice email.</td></tr><tr><td><b class="gd-ui">Send T14 (final notice)</b></td><td>The final notice.</td></tr><tr><td><b class="gd-ui">Request disable</b></td><td>Ask an Admin to approve disabling the car.</td></tr><tr><td><b class="gd-ui">Open an incident</b></td><td>When the car is not coming back as planned.</td></tr></tbody></table></div></section>');
-- GUIDES VEHICLE PAGES END
