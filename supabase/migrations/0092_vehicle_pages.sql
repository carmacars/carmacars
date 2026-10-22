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
  -- the Canadian dimensions and curb weight of each body of the year (NHTSA vPIC GetCanadianVehicleSpecifications)
  dims jsonb not null default '[]'::jsonb check (jsonb_typeof(dims) = 'array'),
  -- NHTSA recall campaigns of the model year [{campaign, date, component, summary}] and complaint counts {total, components}
  recalls jsonb not null default '[]'::jsonb check (jsonb_typeof(recalls) = 'array'),
  complaints jsonb not null default '{}'::jsonb check (jsonb_typeof(complaints) = 'object'),
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
  -- the trim's place in the whole catalog (make, model, year, lineup): the city and colour sitemaps take ranges of it
  ord integer,
  content_hash text,
  updated_at timestamptz not null default now(),
  primary key (make_slug, model_slug, year, slug),
  foreign key (make_slug, model_slug, year) references vehicle_catalog_years (make_slug, model_slug, year) on delete cascade
);
create index vehicle_catalog_trims_slug_idx on vehicle_catalog_trims (make_slug, model_slug, slug);
create index vehicle_catalog_trims_ord_idx on vehicle_catalog_trims (ord) include (make_slug, model_slug, year, slug, updated_at);
-- numbers every trim (dense, from 1), the popular models and the newest years first: the sitemaps and IndexNow go in
-- this order; called after every build of the trims and every change of the popular list
create or replace function app.vehicle_catalog_number_trims() returns void
language plpgsql security definer set search_path = public, app as $$
begin
  update vehicle_catalog_trims t set ord = r.rn
    from (select t.make_slug, t.model_slug, t.year, t.slug,
                 (row_number() over (order by p.sort nulls last, t.year desc, t.make_slug, t.model_slug, t.rank, t.slug))::integer rn
            from vehicle_catalog_trims t left join vehicle_catalog_popular p on p.make_slug = t.make_slug and p.model_slug = t.model_slug) r
   where (t.make_slug, t.model_slug, t.year, t.slug) = (r.make_slug, r.model_slug, r.year, r.slug) and t.ord is distinct from r.rn;
end
$$;

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
  add column if not exists vpage_import_every_days integer not null default 30 check (vpage_import_every_days between 7 and 365),
  add column if not exists vpage_import_db_cap_mb integer not null default 6144 check (vpage_import_db_cap_mb between 100 and 100000);
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
  perform app.vehicle_catalog_number_trims();
  select count(*) into n from vpage_new_trims;
  return n;
end $$;

-- ================================================================ the import (the catalog workflow only)
create or replace function app.vehicle_catalog_import_begin(p jsonb) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid;
  v_cap bigint := (app.settings()).vpage_import_db_cap_mb::bigint * 1024 * 1024;
  v_cat bigint := (select coalesce(sum(pg_total_relation_size(c.oid)), 0) from pg_class c join pg_namespace n on n.oid = c.relnamespace
                    where n.nspname = 'public' and c.relkind = 'r' and c.relname in ('vehicle_catalog_makes', 'vehicle_catalog_models', 'vehicle_catalog_years', 'vehicle_catalog_trims'));
  v_proj bigint;
begin
  -- the database size cap (Admin > Settings > Vehicle pages, 6 GB by default on Supabase Pro's 8 GB): the database as it
  -- is, less today's catalog, plus the catalog this import brings (the import's own estimate)
  v_proj := pg_database_size(current_database()) - v_cat + coalesce((p -> 'stats' ->> 'projected_bytes')::bigint, 0);
  if v_proj > v_cap then
    raise exception 'The import would bring the database to % MB, over the cap of % MB (Admin > Settings > Vehicle pages)', v_proj / 1048576, v_cap / 1048576 using errcode = '54000';
  end if;
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

  insert into vehicle_catalog_years (make_slug, model_slug, year, vclass, variants, dims, recalls, complaints, powertrains, l100_min, l100_max, kwh100_min, ev_range_max, fuels, drives,
                                     sources, import_id, content_hash)
  select v_make, y ->> 'model', (y ->> 'year')::smallint, y ->> 'vclass', coalesce(y -> 'variants', '[]'::jsonb), coalesce(y -> 'dims', '[]'::jsonb),
         coalesce(y -> 'recalls', '[]'::jsonb), coalesce(y -> 'complaints', '{}'::jsonb),
         jsonb_array_length(coalesce(y -> 'variants', '[]'::jsonb)),
         (select min((v ->> 'l100_comb')::numeric) from jsonb_array_elements(y -> 'variants') v),
         (select max((v ->> 'l100_comb')::numeric) from jsonb_array_elements(y -> 'variants') v),
         (select min((v ->> 'kwh100')::numeric) from jsonb_array_elements(y -> 'variants') v),
         (select max((v ->> 'ev_range_km')::integer) from jsonb_array_elements(y -> 'variants') v),
         array(select distinct case v ->> 'fuel' when 'premium' then 'gasoline' else v ->> 'fuel' end from jsonb_array_elements(y -> 'variants') v order by 1),
         array(select distinct v ->> 'drive' from jsonb_array_elements(y -> 'variants') v where v ->> 'drive' is not null order by 1),
         array(select jsonb_array_elements_text(y -> 'sources')), v_imp, md5((y - 'make')::text)
    from jsonb_array_elements(coalesce(p -> 'years', '[]'::jsonb)) y
  on conflict (make_slug, model_slug, year) do update set vclass = excluded.vclass, variants = excluded.variants, dims = excluded.dims, recalls = excluded.recalls, complaints = excluded.complaints, powertrains = excluded.powertrains,
    l100_min = excluded.l100_min, l100_max = excluded.l100_max, kwh100_min = excluded.kwh100_min, ev_range_max = excluded.ev_range_max,
    fuels = excluded.fuels, drives = excluded.drives, sources = excluded.sources, import_id = excluded.import_id, content_hash = excluded.content_hash,
    updated_at = case when vehicle_catalog_years.content_hash is distinct from excluded.content_hash then now() else vehicle_catalog_years.updated_at end;
  get diagnostics n_years = row_count;

  -- the list's trim lines for this make, as the list now has them (an Admin's lines are never touched); a make split
  -- into several batches sends them with its first batch only
  if p ? 'trim_lines' then
    delete from vehicle_catalog_trim_lines where make_slug = v_make and source = 'seed';
    insert into vehicle_catalog_trim_lines (make_slug, model_slug, from_year, to_year, trims, source, sort)
    select v_make, t ->> 'model', (t ->> 'from')::smallint, (t ->> 'to')::smallint, array(select jsonb_array_elements_text(t -> 'trims')), 'seed', i::integer
      from jsonb_array_elements(coalesce(p -> 'trim_lines', '[]'::jsonb)) with ordinality x(t, i);
  end if;
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
    'year', y.year, 'vclass', y.vclass, 'path', app.vpage_path(y.make_slug, y.model_slug, y.year), 'variants', y.variants, 'dims', y.dims, 'sources', y.sources,
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
    'year', y.year, 'vclass', y.vclass, 'body_group', app.vpage_body_group(coalesce(y.vclass, m.vclass)), 'variants', y.variants, 'dims', y.dims, 'sources', y.sources,
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

-- The vehicle sitemaps: one of the makes, then one per make and level ("toyota-models", "toyota-years", "toyota-trims").
-- A file never holds more than 45,000 addresses (the protocol's limit is 50,000): a bigger one is split into
-- "<make>-years-1", "<make>-years-2"... in address order. Only indexed pages, each with its lastmod.
create or replace function app.vehicle_sitemap_files() returns table (file text, urls bigint, lastmod timestamptz)
language sql stable security definer set search_path = public, app as $$
  with f as (
    select case when level = 'make' then 'makes' else make_slug || '-' || level || 's' end base, path, lastmod
      from app.vpage_all() where indexable),
  n as (select base, path, lastmod, (row_number() over (partition by base order by path) - 1) / 45000 + 1 part, count(*) over (partition by base) total from f)
  select case when max(total) > 45000 then base || '-' || part else base end, count(*), max(lastmod) from n group by base, part order by 1
$$;

create or replace function app.vehicle_sitemap(p_file text) returns table (path text, lastmod timestamptz)
language sql stable security definer set search_path = public, app as $$
  with p as (select coalesce(substring(p_file from '^(.*-(?:models|years|trims))-[0-9]+$'), p_file) base,
                    coalesce(substring(p_file from '-([0-9]+)$')::integer, 1) part,
                    p_file ~ '-(models|years|trims)-[0-9]+$' numbered),
  a as (
    select a.path, a.lastmod, row_number() over (order by a.path) rn, count(*) over () total
      from p, app.vpage_all(case when p.base = 'makes' then null else substring(p.base from '^(.*)-(models|years|trims)$') end) a
     where a.indexable and (case when a.level = 'make' then 'makes' else a.make_slug || '-' || a.level || 's' end) = p.base)
  select a.path, a.lastmod from a, p
   where (p.numbered and a.total > 45000 and a.rn > (p.part - 1) * 45000 and a.rn <= p.part * 45000)
      or (not p.numbered and a.total <= 45000)
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
  v_counts jsonb; v_tiers jsonb;
  v_make text; v_model text;
  n integer;
begin
  perform app.assert_admin(p_user);
  case p_name
  when 'vehicle_pages' then
    v_counts := (select coalesce(jsonb_object_agg(level, jsonb_build_object('total', total, 'indexed', indexed)), '{}'::jsonb)
                   from (select level, count(*) total, count(*) filter (where indexable) indexed from app.vpage_all() group by level) c);
    v_tiers := app.vpage_tier_counts(v_counts);
    return jsonb_build_object(
      'settings', app.vpage_settings_json(app.settings()),
      'counts', v_counts,
      'sitemaps', (public.vehicle_sitemap_index(0, 1) ->> 'total')::integer,
      'tiers', v_tiers, 'indexnow', (select to_jsonb(w) from indexnow_sweep w),
      'db', jsonb_build_object('bytes', pg_database_size(current_database()), 'cap_mb', (app.settings()).vpage_import_db_cap_mb,
        'tables', (select coalesce(jsonb_object_agg(c.relname, pg_total_relation_size(c.oid)), '{}'::jsonb) from pg_class c join pg_namespace n on n.oid = c.relnamespace
                    where n.nspname = 'public' and c.relkind = 'r' and (c.relname like 'vehicle_catalog%' or c.relname in ('places', 'place_terms', 'vehicle_colours', 'indexnow_queue', 'indexnow_sweep')))),
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
    perform app.vehicle_catalog_number_trims();
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

-- ================================================================ 5. places, colours, search terms and the twins (the owner, October 22, 2026)
-- Every vehicle page multiplied, every page indexed by default, nothing stored per page (a page is a trim, a place, a
-- colour and a term, read on demand):
--   /cars/<make>/<model>/<year>/<trim>/<place>[/<colour>]   and   /cars/.../<trim>/colour/<colour>      renting
--   /buy/...  (the same tree)                                                                            for sale
--   /t/<term>/...  (the same tree, for each search term: "car hire", "financing", "ceramic coating"...)  a term's twin
-- Places and terms are the local SEO release's (migration 0095, branch seolocal): `places` (every city, town,
-- neighbourhood and airport of Canada, the US and Mexico, with the GTA, provinces, states and countries) and
-- `place_terms` (renting, sale, detailing and body shop terms). This migration runs before 0095 and does not create
-- them: it reads them when they are there (to_regclass, dynamic SQL), and until then the places are the location
-- landing pages and the terms a default list. One Admin switch per tier, all on: places, colours, terms, sale,
-- detailing, body shop. CarmaCars mostly rents: a page says a car is for sale only when an Admin flagged a matching
-- fleet car (then with an Offer), and never says it lends or leases.

create table vehicle_colours (
  slug text primary key check (slug ~ '^[a-z]+$' and slug <> 'colour'),
  name text not null,
  hex text not null check (hex ~ '^#[0-9A-F]{6}$'),
  sort integer not null default 100
);
alter table vehicle_colours enable row level security;
create policy admin_all on vehicle_colours for all to authenticated using (app.is_admin()) with check (app.is_admin());
insert into vehicle_colours (slug, name, hex, sort) values
  ('black', 'Black', '#1C1C1C', 10), ('white', 'White', '#F4F4F4', 20), ('silver', 'Silver', '#8C8C8C', 30), ('grey', 'Grey', '#555555', 40),
  ('blue', 'Blue', '#24477F', 50), ('red', 'Red', '#C20F18', 60), ('green', 'Green', '#2F5E3B', 70), ('brown', 'Brown', '#553923', 80),
  ('beige', 'Beige', '#A8916A', 90), ('gold', 'Gold', '#B8902F', 100), ('orange', 'Orange', '#C2560F', 110), ('yellow', 'Yellow', '#C9A50F', 120);

alter table program_settings
  add column if not exists vpage_place_index boolean not null default true,
  add column if not exists vpage_colour_index boolean not null default true,
  add column if not exists vpage_term_index boolean not null default true,
  add column if not exists vpage_buy_index boolean not null default true,
  add column if not exists vpage_detailing_index boolean not null default true,
  add column if not exists vpage_bodyshop_index boolean not null default true,
  add column if not exists vpage_finance_disclaimer text not null default 'CarmaCars is not a lender, dealer or lessor, and does not arrange financing or leases. We rent cars, and sell one only when it is listed for sale on this page with its price.'
    check (length(vpage_finance_disclaimer) between 20 and 600);

alter table vehicles
  add column if not exists for_sale boolean not null default false,
  add column if not exists asking_price_cents bigint check (asking_price_cents is null or asking_price_cents > 0);

create or replace function app.vpage_settings_json(s program_settings) returns jsonb
language sql immutable as $$
  select jsonb_build_object('index_mode', s.vpage_index_mode, 'model_min_years', s.vpage_model_min_years, 'popular_from_year', s.vpage_popular_from_year,
    'year_min_cars', s.vpage_year_min_cars, 'trim_min_cars', s.vpage_trim_min_cars, 'gas_cents', s.vpage_gas_cents_per_litre,
    'premium_extra_cents', s.vpage_premium_extra_cents, 'elec_cents', s.vpage_electricity_cents_per_kwh,
    'place_index', s.vpage_place_index, 'colour_index', s.vpage_colour_index, 'term_index', s.vpage_term_index, 'buy_index', s.vpage_buy_index,
    'detailing_index', s.vpage_detailing_index, 'bodyshop_index', s.vpage_bodyshop_index, 'finance_disclaimer', s.vpage_finance_disclaimer)
$$;


-- ---------------------------------------------------------------- the local SEO release's tables, when they are here
create or replace function app.vpage_has(p_table text) returns boolean
language sql stable as $$ select to_regclass('public.' || p_table) is not null $$;

-- a place kind of the places table in words (0095: 1 country, 2 province or state, 3 region, 4 area, 5 city or town,
-- 6 neighbourhood, 7 airport, 8 landmark); landmarks have no vehicle pages
create or replace function app.vpage_kind(k integer) returns text
language sql immutable as $$
  select case k when 1 then 'country' when 2 then 'province' when 3 then 'region' when 4 then 'region' when 5 then 'city' when 6 then 'neighbourhood' when 7 then 'airport' else 'landmark' end
$$;

-- The search terms with a tree of their own: place_terms (0095) when it is here (active, not a synonym of another,
-- "car-rental" being the /cars tree itself), else the default list. name: the phrase with a capital ("Car hire").
create or replace function app.vpage_terms() returns table (slug text, name text, kind text, sort integer, lead text)
language plpgsql stable security definer set search_path = public, app as $$
begin
  if app.vpage_has('place_terms') then
    return query execute $q$
      select t.slug, upper(left(t.phrase, 1)) || substr(t.phrase, 2), t.vertical, t.sort_order, t.lead_kind
        from place_terms t where t.is_active and t.canonical_slug is null and t.slug <> 'car-rental' order by t.vertical, t.sort_order, t.slug $q$;
  else
    return query select x.slug, x.name, x.kind, x.sort, x.lead from (values
      ('car-hire', 'Car hire', 'rental', 20, null::text), ('cars-for-hire', 'Cars for hire', 'rental', 30, null), ('vehicle-rental', 'Vehicle rental', 'rental', 40, null),
      ('insurance-replacement', 'Insurance replacement rental', 'rental', 50, null),
      ('used', 'Used', 'sale', 110, 'buyer'), ('financing', 'Financing', 'sale', 120, 'finance'), ('leasing', 'Leasing', 'sale', 130, 'finance'), ('lease-takeover', 'Lease takeover', 'sale', 140, 'finance'),
      ('car-detailing', 'Car detailing', 'detailing', 210, 'detailing'), ('interior-detailing', 'Interior detailing', 'detailing', 220, 'detailing'),
      ('exterior-detailing', 'Exterior detailing', 'detailing', 230, 'detailing'), ('mobile-detailing', 'Mobile detailing', 'detailing', 240, 'detailing'),
      ('paint-correction', 'Paint correction', 'detailing', 250, 'detailing'), ('ceramic-coating', 'Ceramic coating', 'detailing', 260, 'detailing'),
      ('window-tint', 'Window tint', 'detailing', 270, 'detailing'), ('ppf', 'Paint protection film (PPF)', 'detailing', 280, 'detailing'), ('vinyl-wrap', 'Vinyl wrap', 'detailing', 290, 'detailing'),
      ('collision-repair', 'Collision repair', 'bodyshop', 310, 'bodyshop'), ('auto-body', 'Auto body repair', 'bodyshop', 320, 'bodyshop'), ('dent-repair', 'Dent repair', 'bodyshop', 330, 'bodyshop'),
      ('bumper-repair', 'Bumper repair', 'bodyshop', 340, 'bodyshop'), ('car-painting', 'Car painting', 'bodyshop', 350, 'bodyshop'), ('scratch-repair', 'Scratch repair', 'bodyshop', 360, 'bodyshop')
    ) x(slug, name, kind, sort, lead) order by x.kind, x.sort;
  end if;
end $$;

-- the location landing pages as places (until the places table is here), numbered by slug
create or replace function app.vpage_landing_places() returns table (ord integer, slug text, name text, kind text, lat numeric, lng numeric, facts jsonb, updated timestamptz)
language sql stable security definer set search_path = public, app as $$
  select (row_number() over (order by s.slug))::integer, s.slug, s.name, case when s.facts ? 'airport_code' then 'airport' else 'city' end,
         nullif(s.facts ->> 'lat', '')::numeric, nullif(s.facts ->> 'lng', '')::numeric, s.facts, s.content_updated_at
    from seo_pages s where s.kind = 'location' and s.is_active and s.slug <> 'colour'
$$;

-- One place by its slug, if it has vehicle pages (enabled, not a landmark): its name, kind, parent, position, the
-- landing page's facts and path, its number (the sitemaps' place order: the places table's id).
create or replace function app.vpage_place(p_slug text) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare r jsonb;
begin
  if app.vpage_has('places') then
    execute $q$
      select jsonb_build_object('id', p.id, 'ord', p.id, 'slug', p.slug, 'name', p.name, 'kind', app.vpage_kind(p.kind), 'parent', pp.name, 'parent_id', p.parent_id,
             'lat', p.lat, 'lng', p.lng, 'iata', p.iata, 'gta', p.flags & 1 <> 0, 'facts', coalesce(s.facts, '{}'::jsonb),
             'landing', case when s.slug is not null then app.seo_page_path(s.slug) end, 'updated', greatest(s.content_updated_at, p.updated_on::timestamptz))
        from places p left join places pp on pp.id = p.parent_id
        left join seo_pages s on s.slug = coalesce(p.landing_slug, p.slug) and s.kind = 'location' and s.is_active
       where p.slug = $1 and p.kind <> 8 and app.place_enabled(p) $q$ into r using lower(btrim(p_slug));
    return r;
  end if;
  select jsonb_build_object('id', null, 'ord', l.ord, 'slug', l.slug, 'name', l.name, 'kind', l.kind, 'parent', null, 'parent_id', null, 'lat', l.lat, 'lng', l.lng,
         'iata', l.facts ->> 'airport_code', 'gta', true, 'facts', l.facts, 'landing', app.seo_page_path(l.slug), 'updated', l.updated)
    into r from app.vpage_landing_places() l where l.slug = lower(btrim(p_slug));
  return r;
end $$;

-- The places near one (the landing page's own list first, then the nearest of the same parent): local places only.
create or replace function app.vpage_place_near(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare r jsonb;
begin
  if app.vpage_has('places') then
    execute $q$
      select coalesce(jsonb_agg(jsonb_build_object('slug', x.slug, 'name', x.name, 'km', round(x.km::numeric, 1)) order by x.o), '[]'::jsonb) from (
        select n.slug, n.name, app.distance_km($3, $4, n.lat::numeric, n.lng::numeric) km,
               coalesce(array_position($5, n.slug), 100) * 100000 + coalesce(app.distance_km($3, $4, n.lat::numeric, n.lng::numeric), 99999) o
          from places n where n.parent_id = $1 and n.id <> $2 and n.kind in (5, 6, 7) and app.place_enabled(n)
         order by o limit 5) x $q$
      into r using (p ->> 'parent_id')::integer, (p ->> 'id')::integer, (p ->> 'lat')::numeric, (p ->> 'lng')::numeric,
                   array(select jsonb_array_elements_text(coalesce(p -> 'facts' -> 'nearby', '[]'::jsonb)));
    return r;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('slug', x.slug, 'name', x.name, 'km', round(x.km, 1)) order by x.o), '[]'::jsonb) into r from (
    select l.slug, l.name, app.distance_km((p ->> 'lat')::numeric, (p ->> 'lng')::numeric, l.lat, l.lng) km,
           coalesce(array_position(array(select jsonb_array_elements_text(coalesce(p -> 'facts' -> 'nearby', '[]'::jsonb))), l.slug), 100) * 100000
             + coalesce(app.distance_km((p ->> 'lat')::numeric, (p ->> 'lng')::numeric, l.lat, l.lng), 99999) o
      from app.vpage_landing_places() l where l.slug <> p ->> 'slug' order by o limit 5) x;
  return r;
end $$;

-- the places within a region, province or country (the most populous first)
create or replace function app.vpage_place_within(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare r jsonb;
begin
  if not app.vpage_has('places') or p ->> 'id' is null then return '[]'::jsonb; end if;
  execute $q$
    select coalesce(jsonb_agg(jsonb_build_object('slug', x.slug, 'name', x.name) order by x.o), '[]'::jsonb) from (
      select c.slug, c.name, row_number() over (order by c.population desc nulls last, c.name) o from places c
       where c.parent_id = $1 and c.kind <> 8 and app.place_enabled(c) order by c.population desc nulls last, c.name limit 24) x $q$
    into r using (p ->> 'id')::integer;
  return r;
end $$;

-- The places a trim page links to: the countries, provinces, states and areas, then the places with a landing page.
create or replace function app.vpage_place_links() returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare r jsonb;
begin
  if app.vpage_has('places') then
    execute $q$
      select coalesce(jsonb_agg(jsonb_build_object('slug', x.slug, 'name', x.name, 'kind', x.k) order by x.o, x.name), '[]'::jsonb) from (
        (select p.slug, p.name, app.vpage_kind(p.kind) k, p.kind o from places p where p.kind in (1, 4) and app.place_enabled(p))
        union all (select p.slug, p.name, app.vpage_kind(p.kind), 2 from places p where p.kind = 2 and p.country = 'CA' and app.place_enabled(p))
        union all (select p.slug, p.name, app.vpage_kind(p.kind), 5 from places p join seo_pages s on s.slug = p.slug and s.kind = 'location' and s.is_active where app.place_enabled(p))) x $q$ into r;
    return r;
  end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('slug', l.slug, 'name', l.name, 'kind', l.kind) order by l.name), '[]'::jsonb) from app.vpage_landing_places() l);
end $$;

-- the highest place number (the sitemaps' pairs count to it; numbers of places without pages give no address)
create or replace function app.vpage_place_max() returns integer
language plpgsql stable security definer set search_path = public, app as $$
declare n integer;
begin
  if app.vpage_has('places') then execute 'select coalesce(max(id), 0) from places' into n; return n; end if;
  return (select count(*) from app.vpage_landing_places());
end $$;

-- the places with pages among the numbers p_from to p_to (a primary key range on the places table)
create or replace function app.vpage_places_range(p_from integer, p_to integer) returns table (ord integer, slug text, updated timestamptz)
language plpgsql stable security definer set search_path = public, app as $$
begin
  if app.vpage_has('places') then
    return query execute $q$
      select p.id, p.slug, p.updated_on::timestamptz from places p where p.id between $1 and $2 and p.kind <> 8 and app.place_enabled(p) $q$ using p_from, p_to;
  else
    return query select l.ord, l.slug, l.updated from app.vpage_landing_places() l where l.ord between p_from and p_to;
  end if;
end $$;

-- how many places have pages (the Admin's counts: the regions' loaded counts when the places table is here)
create or replace function app.vpage_place_count() returns bigint
language plpgsql stable security definer set search_path = public, app as $$
declare n bigint;
begin
  if app.vpage_has('places') then
    execute 'select coalesce((select sum(places) from place_regions where is_enabled), 0) + (select count(*) from places where kind in (1, 4) and is_active)' into n;
    return n;
  end if;
  return (select count(*) from app.vpage_landing_places());
end $$;

-- What a delivery to a place costs from our lowest delivery fee (the real cars' rate cards, the per-kilometre setting,
-- the minimum, the maximum and the rounding; an airport's own distance and surcharge), as app.delivery_fee counts it.
create or replace function app.vpage_delivery_from(p_km numeric, p_airport text) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  a airports;
  v_base bigint;
  v_km numeric := p_km;
  v_fee bigint;
begin
  select min(rc.delivery_fee_cents) into v_base from app.vpage_cars() c
    join rate_cards rc on rc.vehicle_id = c.vehicle_id and rc.effective_from <= now() and (rc.effective_to is null or rc.effective_to > now())
   where not c.is_sample;
  if p_airport is not null then
    select * into a from airports x where x.is_active and x.code = upper(p_airport);
    if a.id is not null then v_km := coalesce(a.distance_km, app.distance_km(s.company_latitude, s.company_longitude, a.latitude, a.longitude), v_km); end if;
  end if;
  if v_base is null then
    return jsonb_build_object('fee_cents', null, 'km', round(v_km, 1), 'per_km_cents', s.delivery_per_km_cents, 'min_cents', s.delivery_min_cents);
  end if;
  v_fee := v_base;
  if v_km is not null and s.delivery_per_km_cents > 0 then
    v_fee := v_base + round(s.delivery_per_km_cents * v_km)::bigint;
    if s.delivery_min_cents is not null then v_fee := greatest(v_fee, s.delivery_min_cents); end if;
    if s.delivery_max_cents is not null then v_fee := least(v_fee, s.delivery_max_cents); end if;
    v_fee := (round(v_fee::numeric / s.delivery_round_cents) * s.delivery_round_cents)::bigint;
  end if;
  return jsonb_build_object('fee_cents', v_fee + coalesce(a.surcharge_cents, 0), 'km', round(v_km, 1), 'airport_code', a.code, 'airport_name', a.name,
    'airport_surcharge_cents', a.surcharge_cents, 'per_km_cents', s.delivery_per_km_cents);
end $$;


-- The places, colours and terms a trim page links to, the switches, and every term (every page's twins).
create or replace function app.vpage_tiers() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'settings', app.vpage_settings_json(app.settings()),
    'places', app.vpage_place_links(),
    'colours', (select coalesce(jsonb_agg(jsonb_build_object('slug', x.slug, 'name', x.name, 'hex', x.hex) order by x.sort), '[]'::jsonb) from vehicle_colours x),
    'terms', (select coalesce(jsonb_agg(jsonb_build_object('slug', t.slug, 'name', t.name, 'kind', t.kind, 'lead', t.lead) order by t.kind, t.sort, t.slug), '[]'::jsonb) from app.vpage_terms() t))
$$;

-- One place, colour or place and colour page: the trim page's read, and the place (its parent; for a city,
-- neighbourhood or airport its distance from us and the delivery price from our rate cards, the landing page's local
-- notes and the nearby places; for a region, province or country the places within it) and the colour. Null when the
-- trim, place or colour is unknown.
create or replace function app.vehicle_tier_page(p_make text, p_model text, p_year integer, p_trim text, p_place text, p_colour text) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  base jsonb;
  pl jsonb;
  col vehicle_colours;
  v_trim_path text;
  v_path text;
  v_km numeric;
  v_ok boolean;
  v_place jsonb;
  v_local boolean;
begin
  if p_place is null and p_colour is null then return null; end if;
  base := app.vehicle_trim_page(p_make, p_model, p_year, p_trim);
  if base is null then return null; end if;
  v_trim_path := base ->> 'path';
  if p_colour is not null then
    select * into col from vehicle_colours where slug = lower(btrim(p_colour));
    if col.slug is null then return null; end if;
  end if;
  if p_place is not null then
    pl := app.vpage_place(p_place);
    if pl is null then return null; end if;
    v_local := pl ->> 'kind' in ('city', 'neighbourhood', 'airport');
    v_km := case when v_local then app.distance_km(s.company_latitude, s.company_longitude, (pl ->> 'lat')::numeric, (pl ->> 'lng')::numeric) end;
    v_place := jsonb_build_object('slug', pl ->> 'slug', 'name', pl ->> 'name', 'kind', pl ->> 'kind', 'parent', pl ->> 'parent', 'facts', pl -> 'facts', 'landing', pl ->> 'landing',
      'km', round(v_km, 1), 'delivery', case when v_local then app.vpage_delivery_from(v_km, coalesce(pl ->> 'iata', pl -> 'facts' ->> 'airport_code')) end,
      'nearby', case when v_local then app.vpage_place_near(pl) else '[]'::jsonb end,
      'within', case when not v_local then app.vpage_place_within(pl) else '[]'::jsonb end);
  end if;
  v_path := v_trim_path || case when pl is null then '/colour/' || col.slug else '/' || (pl ->> 'slug') || coalesce('/' || col.slug, '') end;
  v_ok := (base ->> 'indexable')::boolean and (pl is null or s.vpage_place_index) and (col.slug is null or s.vpage_colour_index);
  return base || jsonb_build_object(
    'level', case when pl is null then 'colour' when col.slug is null then 'city' else 'city_colour' end,
    'trim_path', v_trim_path, 'path', v_path, 'city', v_place,
    'colour', case when col.slug is not null then jsonb_build_object('slug', col.slug, 'name', col.name, 'hex', col.hex) end,
    'tiers', app.vpage_tiers(), 'indexable', v_ok, 'canonical', case when v_ok then v_path else v_trim_path end,
    'lastmod', greatest((base ->> 'lastmod')::timestamptz, (pl ->> 'updated')::timestamptz));
end $$;

-- ---------------------------------------------------------------- the sitemaps
-- Files are named by tree: "" (renting), "buy-" (for sale) and "t-<term>-" (a term's twin), then the level files
-- ("makes", "toyota-years"...) and the place and colour files "tiers-<n>". A tiers file is a range of (trim, place)
-- pairs: each trim has Q pairs (its places by number, then one more pair for its 12 colour pages), a pair at most 13
-- addresses (the place page and its 12 colours), so a file of floor(50,000 / 13) pairs never passes 50,000 addresses.
-- Pair g is trim ord g / Q + 1 and place number g % Q + 1: a file and each slice of it are read by keyset on g, never by
-- offset (a slice stays within one trim, so its places are one primary key range), and the list of files is arithmetic,
-- so the index never counts addresses. Numbers of places without pages (a disabled region, a landmark) give none.
create or replace function app.vpage_tier_shape() returns table (places integer, q integer, per_pair integer, pairs_per_file integer, trims integer, place_on boolean, colour_on boolean, files integer)
language sql stable security definer set search_path = public, app as $$
  with s as (select app.settings() s),
       n as (select app.vpage_place_max() p, coalesce((select max(ord) from vehicle_catalog_trims), 0) t,
                    ((select s from s)).vpage_place_index po, ((select s from s)).vpage_colour_index co),
       k as (select n.*, (case when n.po then n.p else 0 end) + (case when n.co then 1 else 0 end) q, 50000 / case when n.co then 13 else 1 end ppf from n)
  select k.p, k.q, case when k.co then 13 else 1 end, k.ppf, k.t, k.po, k.co, case when k.q > 0 then ceil((k.t::numeric * k.q) / k.ppf)::integer else 0 end from k
$$;

create or replace function app.vpage_trim_indexed(p_from integer, p_to integer) returns table (ord integer, make_slug text, model_slug text, year smallint, slug text, lastmod timestamptz)
language sql stable security definer set search_path = public, app as $$
  with s as (select app.settings() s),
       cars as materialized (select c.make_slug, c.model_slug, c.year, c.trim_slug, c.content_updated_at from app.vpage_cars() c where not c.is_sample)
  select t.ord, t.make_slug, t.model_slug, t.year, t.slug, greatest(t.updated_at, x.upd)
    from vehicle_catalog_trims t
    left join lateral (select count(*) n, max(c.content_updated_at) upd from cars c where c.make_slug = t.make_slug and c.model_slug = t.model_slug and c.year = t.year and c.trim_slug = t.slug) x on true
   where t.ord > p_from and t.ord <= p_to and app.vpage_gate('trim', 0, coalesce(x.n, 0)::integer, false, t.year, (select s from s))
   order by t.ord
$$;

-- One slice of a tiers file: the addresses of up to p_limit pairs of file p_file after pair p_after (keyset), within
-- one trim.
create or replace function app.vehicle_tier_sitemap(p_file integer, p_after bigint, p_limit integer) returns table (g bigint, path text, lastmod timestamptz)
language plpgsql stable security definer set search_path = public, app as $$
declare
  sh record;
  v_a bigint; v_b bigint;
  v_ord integer; v_p1 integer; v_p2 integer;
  t record;
begin
  select * into sh from app.vpage_tier_shape();
  if sh.q = 0 or p_file < 1 or p_file > sh.files then return; end if;
  v_a := greatest((p_file - 1)::bigint * sh.pairs_per_file, coalesce(p_after, -1) + 1);
  v_ord := (v_a / sh.q + 1)::integer;
  v_b := least(p_file::bigint * sh.pairs_per_file, sh.trims::bigint * sh.q, v_ord::bigint * sh.q, v_a + greatest(1, least(coalesce(p_limit, 200), 4000))) - 1;
  if v_b < v_a then return; end if;
  v_p1 := (v_a % sh.q + 1)::integer; v_p2 := (v_b % sh.q + 1)::integer;
  select * into t from app.vpage_trim_indexed(v_ord - 1, v_ord);
  if t.ord is null then
    -- a trim out of search (the rules): its pairs give nothing; the slice still ends where it ends
    g := v_b; path := null; lastmod := null; return next; return;
  end if;
  return query
    select (v_ord - 1)::bigint * sh.q + x.pidx - 1, app.vpage_path(t.make_slug, t.model_slug, t.year, t.slug) || x.tail, greatest(t.lastmod, x.upd)
      from (
        select pl.ord pidx, '/' || pl.slug tail, pl.updated upd, 0 o from app.vpage_places_range(v_p1, least(v_p2, sh.places)) pl where sh.place_on
        union all select pl.ord, '/' || pl.slug || '/' || k.slug, pl.updated, k.sort from app.vpage_places_range(v_p1, least(v_p2, sh.places)) pl cross join vehicle_colours k where sh.place_on and sh.colour_on
        union all select sh.q, '/colour/' || k.slug, null, k.sort from vehicle_colours k where sh.colour_on and v_p2 = sh.q and (not sh.place_on or sh.q > sh.places)) x
     order by 1, x.o, x.tail;
  -- the last pair of the slice, so the next one starts after it even when its places have no pages
  g := v_b; path := null; lastmod := null; return next;
end $$;

-- The trees and their prefixes, as the switches allow: renting always, for sale, each term.
create or replace function app.vpage_trees() returns table (prefix text, term text, kind text)
language sql stable security definer set search_path = public, app as $$
  with s as (select app.settings() s)
  select x.prefix, x.term, x.kind from (
    select '' prefix, null::text term, 'rental' kind, 0 o, 0 so
    union all select 'buy-', null, 'sale', 1, 0 where ((select s from s)).vpage_buy_index
    union all select 't-' || t.slug || '-', t.slug, t.kind, 2, t.sort from app.vpage_terms() t, s
     where case t.kind when 'rental' then (s.s).vpage_term_index when 'sale' then (s.s).vpage_term_index and (s.s).vpage_buy_index
                       when 'detailing' then (s.s).vpage_detailing_index else (s.s).vpage_bodyshop_index end) x
   order by x.o, x.kind, x.so, x.term
$$;

-- The sitemap index of the vehicle pages, a page of it: every tree (renting, /buy, each term) has the level files then
-- tiers-1 to tiers-N. Arithmetic: no address and no file is counted, only the level files are read (one query).
create or replace function app.vpage_index_page(p_offset bigint, p_limit integer) returns table (i bigint, file text, lastmod timestamptz, total bigint)
language plpgsql stable security definer set search_path = public, app as $$
declare
  base text[]; base_lm timestamptz[]; nb integer; nt integer; per bigint; trees text[]; v_total bigint;
begin
  select coalesce(array_agg(f.file order by f.file), '{}'), coalesce(array_agg(f.lastmod order by f.file), '{}') into base, base_lm from app.vehicle_sitemap_files() f;
  nb := cardinality(base);
  select files into nt from app.vpage_tier_shape();
  per := nb + coalesce(nt, 0);
  select coalesce(array_agg(t.prefix), '{}') into trees from app.vpage_trees() t;
  v_total := per * cardinality(trees);
  return query
    select x.n, trees[((x.n - 1) / per)::integer + 1] || case when (x.n - 1) % per < nb then base[((x.n - 1) % per)::integer + 1] else 'tiers-' || ((x.n - 1) % per - nb + 1) end,
           case when (x.n - 1) % per < nb then base_lm[((x.n - 1) % per)::integer + 1] end, v_total
      from generate_series(p_offset + 1, least(p_offset + greatest(p_limit, 0), v_total)) x(n);
  if v_total = 0 or p_offset >= v_total then return query select 0::bigint, null::text, null::timestamptz, v_total; end if;
end $$;

create or replace function public.vehicle_sitemap_index(p_offset integer, p_limit integer) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with e as materialized (select * from app.vpage_index_page(p_offset, least(p_limit, 50000)))
  select jsonb_build_object('total', coalesce((select max(total) from e), 0),
    'files', coalesce((select jsonb_agg(jsonb_build_object('file', x.file, 'lastmod', x.lastmod) order by x.i) from e x where x.file is not null), '[]'::jsonb))
$$;
-- a tree's prefix is allowed now (a file of a tree switched off is a 404), and how many tiers files there are
create or replace function public.vehicle_sitemap_tree(p_prefix text) returns boolean
language sql stable security definer set search_path = public, app as $$ select exists (select 1 from app.vpage_trees() where prefix = p_prefix) $$;
create or replace function public.vehicle_tier_files_count() returns integer
language sql stable security definer set search_path = public, app as $$ select files from app.vpage_tier_shape() $$;
create or replace function public.vehicle_tier_sitemap(p_file integer, p_after bigint, p_limit integer) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('g', s.g, 'path', s.path, 'lastmod', s.lastmod) order by s.g, s.path nulls last), '[]'::jsonb) from app.vehicle_tier_sitemap(p_file, p_after, p_limit) s
$$;
create or replace function public.vehicle_tier_page(p_make text, p_model text, p_year integer, p_trim text, p_place text, p_colour text) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.vehicle_tier_page(p_make, p_model, p_year, p_trim, p_place, p_colour) $$;
create or replace function public.vehicle_tiers() returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.vpage_tiers() $$;

-- The Admin's counts of every tier: a tree (renting, for sale, each term) has the level pages, the place pages, the
-- place and colour pages and the colour pages of every trim.
create or replace function app.vpage_tier_counts(p_counts jsonb) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with s as (select app.settings() s),
       sh as (select * from app.vpage_tier_shape()),
       pc as (select app.vpage_place_count() n),
       t as (select count(*) total from vehicle_catalog_trims),
       ti as (select count(*) n from app.vpage_trim_indexed(0, 2147483647)),
       b as (select coalesce(sum((v ->> 'total')::bigint), 0) total, coalesce(sum((v ->> 'indexed')::bigint), 0) indexed from jsonb_each(p_counts) e(k, v)),
       c as (select count(*) filter (where kind = 'rental') r, count(*) filter (where kind = 'sale') sa, count(*) filter (where kind = 'detailing') d, count(*) filter (where kind = 'bodyshop') bs from app.vpage_terms()),
       tree as (select b.total + t.total * pc.n * 13 + t.total * 12 total,
                       b.indexed + case when sh.place_on then ti.n * pc.n else 0 end + case when sh.place_on and sh.colour_on then ti.n * pc.n * 12 else 0 end
                         + case when sh.colour_on then ti.n * 12 else 0 end indexed from b, t, ti, sh, pc)
  select jsonb_build_object('places', pc.n, 'colours', 12, 'trims', t.total, 'trims_indexed', ti.n, 'files_per_tree', sh.files,
    'place', jsonb_build_object('total', t.total * pc.n, 'indexed', case when sh.place_on then ti.n * pc.n else 0 end),
    'place_colour', jsonb_build_object('total', t.total * pc.n * 12, 'indexed', case when sh.place_on and sh.colour_on then ti.n * pc.n * 12 else 0 end),
    'colour', jsonb_build_object('total', t.total * 12, 'indexed', case when sh.colour_on then ti.n * 12 else 0 end),
    'tree', jsonb_build_object('total', tree.total, 'indexed', tree.indexed),
    'sale', jsonb_build_object('total', tree.total, 'indexed', case when (s.s).vpage_buy_index then tree.indexed else 0 end),
    'rental_terms', jsonb_build_object('terms', c.r, 'total', tree.total * c.r, 'indexed', case when (s.s).vpage_term_index then tree.indexed * c.r else 0 end),
    'sale_terms', jsonb_build_object('terms', c.sa, 'total', tree.total * c.sa, 'indexed', case when (s.s).vpage_term_index and (s.s).vpage_buy_index then tree.indexed * c.sa else 0 end),
    'detailing_terms', jsonb_build_object('terms', c.d, 'total', tree.total * c.d, 'indexed', case when (s.s).vpage_detailing_index then tree.indexed * c.d else 0 end),
    'bodyshop_terms', jsonb_build_object('terms', c.bs, 'total', tree.total * c.bs, 'indexed', case when (s.s).vpage_bodyshop_index then tree.indexed * c.bs else 0 end),
    'for_sale', (select count(*) from vehicles where for_sale and asking_price_cents is not null and not is_sample))
    from s, sh, pc, t, ti, tree, c
$$;

-- ---------------------------------------------------------------- the /buy twins: for sale only when a car really is
-- Fleet cars flagged for sale that match a page (make, and the model, year and trim when the page has them).
create or replace function app.vpage_for_sale(p_make text, p_model text, p_year integer, p_trim text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('name', concat_ws(' ', v.year, v.make, v.model, v.trim), 'year', v.year, 'colour', v.colour, 'odometer_km', v.odometer_km,
           'asking_price_cents', v.asking_price_cents, 'trim_slug', m.trim_slug, 'model_slug', m.model_slug,
           'listing', case when l.status = 'published' and l.slug is not null then app.public_listing_row(v.id) end) order by v.asking_price_cents nulls last, v.year desc), '[]'::jsonb)
    from vehicles v cross join lateral app.vehicle_catalog_match(v.make, v.model, v.year, v.trim) m
    left join vehicle_listings l on l.vehicle_id = v.id
   where v.for_sale and v.asking_price_cents is not null and not v.is_sample and v.status not in ('exited', 'total_loss', 'declined')
     and m.make_slug = p_make and (p_model is null or m.model_slug = p_model) and (p_year is null or v.year = p_year) and (p_trim is null or m.trim_slug = p_trim)
$$;

-- What a /buy page adds to its /cars twin: the cars for sale, the model year's recalls and complaints (or the model's by
-- year), and the switches.
create or replace function app.vehicle_buy_extras(p_make text, p_model text, p_year integer, p_trim text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'for_sale', app.vpage_for_sale(lower(p_make), lower(p_model), p_year, lower(p_trim)),
    'buy_index', (app.settings()).vpage_buy_index,
    -- null when NHTSA's files were not imported for the year (then the page says nothing about recalls, never "none")
    'recalls', case when p_year is not null then (select case when y.complaints ? 'total' then y.recalls end from vehicle_catalog_years y where y.make_slug = lower(p_make) and y.model_slug = lower(p_model) and y.year = p_year) end,
    'complaints', case when p_year is not null then (select case when y.complaints ? 'total' then y.complaints end from vehicle_catalog_years y where y.make_slug = lower(p_make) and y.model_slug = lower(p_model) and y.year = p_year) end,
    'by_year', case when p_year is null and p_model is not null then (select coalesce(jsonb_agg(jsonb_build_object('year', y.year, 'recalls', jsonb_array_length(y.recalls),
                    'complaints', coalesce((y.complaints ->> 'total')::integer, 0)) order by y.year desc), '[]'::jsonb)
                    from vehicle_catalog_years y where y.make_slug = lower(p_make) and y.model_slug = lower(p_model) and y.complaints ? 'total') end)
$$;
create or replace function public.vehicle_buy_extras(p_make text, p_model text, p_year integer, p_trim text) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.vehicle_buy_extras(p_make, p_model, p_year, p_trim) $$;

-- ---------------------------------------------------------------- leads from the twins: buyer, finance, detailing
-- the kinds are added to whatever the constraint already allows (the local SEO release adds its own the same way)
do $$
declare
  d text;
  v text[];
begin
  select pg_get_constraintdef(oid) into d from pg_constraint where conrelid = 'leads'::regclass and conname = 'leads_kind_check';
  v := array(select distinct x from (select (regexp_matches(coalesce(d, ''), '''([a-z_]+)''', 'g'))[1] x
                                     union all select unnest(array['owner_program', 'contact', 'insurer', 'launch_notice', 'other', 'chat', 'sample_car', 'buyer', 'finance', 'detailing', 'bodyshop'])) k order by 1);
  execute 'alter table leads drop constraint if exists leads_kind_check';
  execute format('alter table leads add constraint leads_kind_check check (kind = any (%L::text[]))', v);
end $$;
insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, procedure_no, completion_rule, description) values
  ('buyer_lead', 'sales', 'A buyer asked us to find a car', 'normal', 'business_days', 1, null, null, 'Reply in 1 business day: a car of ours for sale, or what we can find'),
  ('finance_lead', 'sales', 'Someone asked about financing or leasing a car', 'normal', 'business_days', 1, null, null, 'Reply in 1 business day. We do not lend or lease: offer a car of ours for sale if there is one, or renting first'),
  ('detailing_lead', 'sales', 'A detailing request', 'normal', 'business_days', 1, null, null, 'Reply in 1 business day with a time and a price, and offer a rental while the car is in'),
  ('bodyshop_lead', 'sales', 'A body shop request', 'normal', 'business_days', 1, null, null, 'Reply in 1 business day, and offer an insurance replacement rental while the car is repaired')
on conflict (task_type) do nothing;

alter function app.submit_lead(jsonb, text) rename to submit_lead_pre0092;
create or replace function app.submit_lead(p jsonb, p_ip text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_kind text := coalesce(p ->> 'kind', 'contact');
  v_id uuid := gen_random_uuid();
  v_email text := nullif(lower(btrim(p ->> 'email')), '');
  v_phone text := nullif(btrim(p ->> 'phone'), '');
  v_name text := nullif(btrim(p ->> 'name'), '');
  v_consent boolean := coalesce((p ->> 'consent_marketing')::boolean, false);
  v_set program_settings := app.settings();
  v_assignee uuid;
  v_task uuid;
  v_car text := nullif(btrim(p -> 'payload' ->> 'vehicle'), '');
  v_what text := nullif(btrim(p -> 'payload' ->> 'service'), '');
begin
  if v_kind not in ('buyer', 'finance', 'detailing', 'bodyshop') then return app.submit_lead_pre0092(p, p_ip); end if;
  if nullif(btrim(p_ip), '') is not null and not app.rate_limit('lead:ip:' || btrim(p_ip), v_set.lead_hourly_limit, interval '1 hour') then
    return jsonb_build_object('ok', false, 'error', 'rate_limited');
  end if;
  if v_email is null and v_phone is null then raise exception 'Give an email address or a phone number so we can reply' using errcode = '22023'; end if;
  if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter a full email address, for example name@example.com' using errcode = '22023'; end if;
  if v_consent and nullif(p ->> 'consent_text', '') is null then raise exception 'Marketing consent needs the wording the person agreed to' using errcode = '22023'; end if;
  -- Sales: the least busy active sales assistant
  select sp.user_id into v_assignee from staff_profiles sp join users u on u.id = sp.user_id and u.status = 'active'
    join user_roles r on r.user_id = sp.user_id and r.role = 'va'
   where sp.staff_type = 'va' and sp.va_function = 'sales' and sp.is_active
   order by (select count(*) from leads l where l.assigned_to = sp.user_id and l.status in ('new', 'contacted', 'qualified')), sp.created_at, sp.user_id limit 1;
  insert into leads (id, kind, name, email, phone, message, payload, source, source_url, referrer, consent_marketing, consent_text, consent_at, assigned_to)
  values (v_id, v_kind, v_name, v_email, v_phone, nullif(btrim(p ->> 'message'), ''), app.strip_transient(coalesce(p -> 'payload', '{}'::jsonb)),
          coalesce(nullif(p ->> 'source', ''), 'web'), p ->> 'source_url', p ->> 'referrer',
          v_consent, case when v_consent then p ->> 'consent_text' end, case when v_consent then now() end, v_assignee);
  v_task := app.raise_task(p_type => v_kind || '_lead',
    p_detail => case v_kind
      when 'detailing' then concat_ws(' ', coalesce(v_name, 'Someone'), 'asked for', coalesce(lower(v_what), 'detailing'), 'on', coalesce(v_car, 'a car') || '.',
                                      'Where: ' || nullif(btrim(p -> 'payload' ->> 'place'), '') || '.', 'When: ' || nullif(btrim(p -> 'payload' ->> 'timeline'), '') || '.')
      when 'bodyshop' then concat_ws(' ', coalesce(v_name, 'Someone'), 'asked for', coalesce(lower(v_what), 'body work'), 'on', coalesce(v_car, 'a car') || '.',
                                      'Where: ' || nullif(btrim(p -> 'payload' ->> 'place'), '') || '.', 'When: ' || nullif(btrim(p -> 'payload' ->> 'timeline'), '') || '.')
      else concat_ws(' ', coalesce(v_name, 'Someone'), case v_kind when 'finance' then 'asked about ' || coalesce(lower(v_what), 'financing') || ' for' else 'wants to buy' end,
                     coalesce(v_car, 'a car') || '.', 'Budget: ' || nullif(btrim(p -> 'payload' ->> 'budget'), '') || '.', 'Timeline: ' || nullif(btrim(p -> 'payload' ->> 'timeline'), '') || '.') end,
    p_related_table => 'leads', p_related_id => v_id, p_dedupe => 'lead:' || v_id);
  if v_assignee is not null then update tasks set assigned_to = v_assignee where id = v_task; end if;
  return jsonb_build_object('ok', true, 'lead_id', v_id);
end $$;
revoke all on function app.submit_lead_pre0092(jsonb, text) from public, anon, authenticated;
grant execute on function app.submit_lead_pre0092(jsonb, text) to service_role;
revoke all on function app.submit_lead(jsonb, text) from public, anon, authenticated;
grant execute on function app.submit_lead(jsonb, text) to service_role;

-- ---------------------------------------------------------------- an Admin flags a fleet car for sale
create or replace function app.vpage_for_sale_set(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid := (p ->> 'vehicle_id')::uuid;
  v_on boolean := coalesce((p ->> 'for_sale')::boolean, false);
  v_price bigint := nullif(p ->> 'asking_price_cents', '')::bigint;
begin
  perform app.assert_admin(p_user);
  if v_on and (v_price is null or v_price <= 0) then raise exception 'Enter the asking price' using errcode = '22023'; end if;
  update vehicles set for_sale = v_on, asking_price_cents = case when v_on then v_price else asking_price_cents end where id = v_id;
  if not found then raise exception 'Car not found' using errcode = 'P0002'; end if;
  return jsonb_build_object('ok', true);
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0092b;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'admin_do' and p_name = 'vehicle_for_sale' then
    perform app.door_begin(p_user, p_aal);
    return app.vpage_for_sale_set(p_user, coalesce(p, '{}'::jsonb));
  end if;
  return app.door_pre0092b(p_user, p_aal, p_call, p_name, p);
end $$;

-- ---------------------------------------------------------------- IndexNow: every page, as fast as the engines allow
-- One queue and one quota for the whole site (shared with the local SEO release): indexnow_queue holds the addresses
-- whose content changed (sent first, by the search job, 0061); indexnow_sweep walks every address of the vehicle
-- sitemaps in their order (the popular models and the newest years first, the GTA first within each) with a cursor, in
-- batches of up to 10,000 (IndexNow's most per request), as often as the job runs, within a daily ceiling. A 429 or 403
-- backs off (doubling from 15 minutes; a 403 or 422 until the next day) and the sweep resumes where it stopped.
create table indexnow_sweep (
  id boolean primary key default true check (id),
  file_i integer not null default 0,
  pos bigint not null default -1,
  day date not null default (now() at time zone 'America/Toronto')::date,
  sent_today integer not null default 0,
  backoff_until timestamptz,
  backoff_s integer not null default 0,
  rounds integer not null default 0,
  last_status integer,
  last_error text,
  last_at timestamptz,
  updated_at timestamptz not null default now()
);
comment on table indexnow_sweep is 'The IndexNow sweep of every vehicle page (0092): where it is in the sitemap index (file_i, and pos: the row of a level file or the pair of a tiers file last sent), the addresses sent today (every sender counts here), and the back-off after a 429 or 403.';
insert into indexnow_sweep default values;
alter table indexnow_sweep enable row level security;
create policy admin_all on indexnow_sweep for select to authenticated using (app.is_admin());
alter table program_settings
  add column if not exists indexnow_daily_max integer not null default 2000000 check (indexnow_daily_max between 0 and 100000000),
  add column if not exists indexnow_batch integer not null default 10000 check (indexnow_batch between 1 and 10000);

-- The next batch: up to p_limit addresses after the cursor (the n-th file of the index and the row or pair in it),
-- within today's ceiling; nothing while backing off. The index is the arithmetic list of app.vpage_index_page.
create or replace function app.server_indexnow_claim(p_limit integer) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  w indexnow_sweep;
  v_today date := (now() at time zone 'America/Toronto')::date;
  v_room integer;
  v_paths text[] := '{}';
  v_more text[];
  base text[]; nb integer; nt integer; per bigint; trees text[]; v_total bigint;
  v_i bigint; v_pos bigint; v_last bigint;
  v_prefix text; v_k bigint; v_steps integer := 0;
begin
  select * into w from indexnow_sweep for update;
  if w.day < v_today then update indexnow_sweep set day = v_today, sent_today = 0 returning * into w; end if;
  if not s.indexnow_enabled then return jsonb_build_object('paths', '[]'::jsonb, 'why', 'off'); end if;
  if w.backoff_until > now() then return jsonb_build_object('paths', '[]'::jsonb, 'why', 'backing off', 'until', w.backoff_until); end if;
  v_room := least(coalesce(p_limit, s.indexnow_batch), s.indexnow_batch, greatest(s.indexnow_daily_max - w.sent_today, 0));
  if v_room <= 0 then return jsonb_build_object('paths', '[]'::jsonb, 'why', 'daily ceiling'); end if;
  select coalesce(array_agg(f.file order by f.file), '{}') into base from app.vehicle_sitemap_files() f;
  nb := cardinality(base);
  select files into nt from app.vpage_tier_shape();
  per := nb + coalesce(nt, 0);
  select coalesce(array_agg(t.prefix), '{}') into trees from app.vpage_trees() t;
  v_total := per * cardinality(trees);
  if v_total = 0 then return jsonb_build_object('paths', '[]'::jsonb, 'why', 'nothing to send'); end if;
  v_i := w.file_i; v_pos := w.pos;
  if v_i >= v_total then v_i := 0; v_pos := -1; end if;
  -- at most 5,000 steps a batch (pairs of places without pages give no address, only progress)
  while cardinality(v_paths) < v_room and v_i < v_total and v_steps < 5000 loop
    v_steps := v_steps + 1;
    v_prefix := trees[(v_i / per)::integer + 1];
    v_k := v_i % per;
    v_last := null; v_more := '{}';
    if v_k >= nb then
      -- a pair is up to 13 addresses: stop when the batch has no room for one more
      exit when v_room - cardinality(v_paths) < 13 and cardinality(v_paths) > 0;
      select coalesce(array_agg(app.vpage_tree_path(v_prefix, x.path) order by x.g, x.path) filter (where x.path is not null), '{}'), max(x.g) into v_more, v_last
        from app.vehicle_tier_sitemap((v_k - nb + 1)::integer, v_pos, greatest(1, (v_room - cardinality(v_paths)) / 13)) x;
    else
      select coalesce(array_agg(app.vpage_tree_path(v_prefix, x.path) order by x.rn), '{}'), max(x.rn) into v_more, v_last
        from (select r.path, row_number() over (order by r.path) rn from app.vehicle_sitemap(base[v_k + 1]) r) x
       where x.rn > v_pos and x.rn <= v_pos + (v_room - cardinality(v_paths));
    end if;
    v_paths := v_paths || v_more;
    if v_last is null then v_i := v_i + 1; v_pos := -1; else v_pos := v_last; end if;
  end loop;
  return jsonb_build_object('paths', to_jsonb(v_paths), 'cursor', jsonb_build_object('file_i', v_i, 'pos', v_pos), 'files', v_total,
    'key', (select indexnow_key from site_settings limit 1));
end $$;
create or replace function app.vpage_tree_path(p_prefix text, p_path text) returns text
language sql immutable as $$
  select case when p_prefix = '' then p_path when p_prefix = 'buy-' then '/buy' || substr(p_path, 6)
              else '/t/' || substring(p_prefix from '^t-(.*)-$') || substr(p_path, 6) end
$$;

-- What the batch got: 2xx moves the cursor and counts the addresses; 429 backs off (15 minutes, doubling, at most a day);
-- 403 or 422 (the key refused) waits until tomorrow; anything else waits 10 minutes. The cursor stays put on a failure.
create or replace function app.server_indexnow_report(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_status integer := coalesce((p ->> 'status')::integer, 0);
  v_n integer := coalesce((p ->> 'count')::integer, 0);
  w indexnow_sweep;
  v_wait integer;
begin
  select * into w from indexnow_sweep for update;
  if v_status between 200 and 299 then
    update indexnow_sweep set sent_today = sent_today + v_n, backoff_s = 0, backoff_until = null, last_status = v_status, last_error = null, last_at = now(), updated_at = now(),
           file_i = case when p -> 'cursor' is not null then (p -> 'cursor' ->> 'file_i')::integer else file_i end,
           pos = case when p -> 'cursor' is not null then (p -> 'cursor' ->> 'pos')::bigint else pos end
     returning * into w;
    -- the whole list sent: start again from the top (lastmod tells the engines what changed)
    if (p ->> 'files') is not null and w.file_i >= (p ->> 'files')::integer then update indexnow_sweep set file_i = 0, pos = -1, rounds = rounds + 1 returning * into w; end if;
  else
    v_wait := case when v_status = 429 then least(greatest(w.backoff_s * 2, 900), 86400)
                   when v_status in (403, 422) then greatest(60, extract(epoch from (((now() at time zone 'America/Toronto')::date + 1 + time '00:05') at time zone 'America/Toronto') - now())::integer)
                   else 600 end;
    update indexnow_sweep set backoff_s = v_wait, backoff_until = now() + make_interval(secs => v_wait), last_status = v_status, last_error = left(p ->> 'error', 300),
           last_at = now(), updated_at = now() returning * into w;
  end if;
  return to_jsonb(w);
end $$;
-- the changed addresses (0061's sender) count against the same ceiling and back off the same way
create or replace function app.server_indexnow_sent(p jsonb) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  v_ok boolean := coalesce((p ->> 'status')::integer, 0) between 200 and 299;
  n integer;
begin
  update indexnow_queue set attempts = attempts + 1, last_status = (p ->> 'status')::integer, last_error = left(p ->> 'error', 300),
         sent_at = case when v_ok then now() else sent_at end
   where path = any (array(select jsonb_array_elements_text(coalesce(p -> 'paths', '[]'::jsonb))));
  get diagnostics n = row_count;
  perform app.server_indexnow_report(jsonb_build_object('status', p ->> 'status', 'count', n, 'error', p ->> 'error'));
  return n;
end $$;
create or replace function public.server_indexnow_claim(p_limit integer) returns jsonb
language sql security definer set search_path = public, app as $$ select app.server_indexnow_claim(p_limit) $$;
create or replace function public.server_indexnow_report(p jsonb) returns jsonb
language sql security definer set search_path = public, app as $$ select app.server_indexnow_report(p) $$;

-- ---------------------------------------------------------------- privileges
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname in ('vpage_has', 'vpage_kind', 'vpage_terms', 'vpage_landing_places', 'vpage_place', 'vpage_place_near', 'vpage_place_within',
                    'vpage_place_links', 'vpage_place_max', 'vpage_places_range', 'vpage_place_count', 'vpage_delivery_from', 'vpage_tiers', 'vehicle_tier_page',
                    'vpage_tier_shape', 'vpage_trim_indexed', 'vehicle_tier_sitemap', 'vpage_trees', 'vpage_index_page', 'vpage_tier_counts', 'vehicle_catalog_number_trims',
                    'vpage_settings_json', 'vpage_for_sale', 'vehicle_buy_extras', 'vpage_for_sale_set', 'door_pre0092b', 'door', 'server_indexnow_claim', 'server_indexnow_report',
                    'vpage_tree_path')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
grant execute on function app.vpage_has(text), app.vpage_kind(integer), app.vpage_terms(), app.vpage_landing_places(), app.vpage_place(text), app.vpage_place_near(jsonb),
  app.vpage_place_within(jsonb), app.vpage_place_links(), app.vpage_place_max(), app.vpage_places_range(integer, integer), app.vpage_delivery_from(numeric, text), app.vpage_tiers(),
  app.vehicle_tier_page(text, text, integer, text, text, text), app.vpage_tier_shape(), app.vpage_trim_indexed(integer, integer), app.vehicle_tier_sitemap(integer, bigint, integer),
  app.vpage_trees(), app.vpage_index_page(bigint, integer), app.vehicle_buy_extras(text, text, integer, text), app.vpage_tree_path(text, text) to anon, authenticated;
revoke all on function public.vehicle_sitemap_index(integer, integer), public.vehicle_sitemap_tree(text), public.vehicle_tier_files_count(), public.vehicle_tier_sitemap(integer, bigint, integer),
  public.vehicle_tier_page(text, text, integer, text, text, text), public.vehicle_tiers(), public.vehicle_buy_extras(text, text, integer, text),
  public.server_indexnow_claim(integer), public.server_indexnow_report(jsonb) from public;
grant execute on function public.vehicle_sitemap_index(integer, integer), public.vehicle_sitemap_tree(text), public.vehicle_tier_files_count(), public.vehicle_tier_sitemap(integer, bigint, integer),
  public.vehicle_tier_page(text, text, integer, text, text, text), public.vehicle_tiers(), public.vehicle_buy_extras(text, text, integer, text) to anon, authenticated, service_role;
grant execute on function public.server_indexnow_claim(integer), public.server_indexnow_report(jsonb) to service_role;
revoke all on vehicle_colours, indexnow_sweep from anon, authenticated;
grant select on vehicle_colours to authenticated;
grant all on vehicle_colours, indexnow_sweep to service_role;
select app.vehicle_catalog_number_trims();

-- ================================================================ the guides (Admin: Vehicle pages; customer service: A request from a vehicle page)
-- GUIDES VEHICLE PAGES START (generated by supabase/seed/vehicle_pages_gen_guides.mjs from docs/guides/content; do not edit by hand)
select app.guide_release_section('renter', 'find-a-car-and-send-a-request', 'chapter', 'start-here', 'Every booking starts as a request. A person checks the car and the price, then sends you an offer. Nothing is charged until you approve, sign and pay.

:::flow
Request | You pick a car and dates
Offer | We confirm the price
Sign | The rental agreement
Pay | Your card is authorized
Verify | Licence, selfie, coverage
Pick up | We hand over the keys
:::

## Find a car

Start on carmacars.ca. You do not need to sign in to look around.

1. Go to `carmacars.ca` and press **Find a car**.
2. Add your pickup and return dates. The list then shows the cars that are free and what the whole trip costs.
3. Narrow the list with Filters: type, seats, transmission and daily rate.
4. Open a car to see its photos, rates, what is included and its own calendar.

![](/guides/img/public-02-cars-desktop-b6cd4fb8.jpg "desktop; size: 1440 880; address: carmacars.ca/cars; pins: 1 86.1 4.0, 2 11.1 56.8, 3 3.0 82.3, 4 34.0 87.5")

## Choose your dates on the car page

1. Under Dates and price, tap your pickup date, then your return date. Hatched days are already booked.
2. Choose the Pickup time and the Return time.
3. Want it brought to you? Tick **Deliver it to me** or **Pick it up from me at the end**. Open Add-ons to add a baby seat, flowers, a full tank and more.
4. Check Your estimate, then press **Request to book**. The add-ons you chose come with you.

![](/guides/img/public-03-car-page-desktop-73be4d63.jpg "desktop; size: 1120 760; address: carmacars.ca/cars/bmw-330i; pins: 1 24.4 39.7, 2 12.9 68.2, 3 3.0 76.2, 4 97.0 50.0")

> Watch out: A request does not hold the car. The car is booked only once you approve the offer, sign and pay.

## Send your request

The request has five short steps. Your answers are saved as you go, so you can come back.

1. Step 1, Dates and delivery: check the car and tap your dates in the calendar.
2. Set the Pickup time and Return time. Any time, day or night, with at least 2 hours of notice.
3. Your request, on the right, shows the estimated total as you go.

![](/guides/img/public-04-book-1-trip-desktop-63a3738b.jpg "desktop; size: 1440 1002; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 1 9.2 67.1, 2 15.3 91.0, 3 91.1 54.7")

4. Choose where you get the car: **At our location**, **Deliver it to an address** or **At the airport**. Then choose where you return it.
5. Press **Continue to driver details**.

![](/guides/img/public-04-book-1-trip-desktop-befba4f6.jpg "desktop; size: 760 942; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 4 5.3 26.2, 5 61.8 93.3")

6. Step 2, The driver: fill in your first and last name, email, mobile number and date of birth.
7. Someone else will drive too? Add them under Additional drivers. Each needs a G2 or G licence and signs the agreement.
8. Press **Continue to licence**.

![](/guides/img/public-05-book-2-driver-desktop-7b572499.jpg "desktop; size: 980 1032; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 6 30.6 21.1, 7 30.6 64.8, 8 55.6 88.0")

9. Step 3: choose your Licence class, for example Ontario G2.
10. Choose how the car is covered: Option 1 (OPCF 27 on your own auto policy), Option 2 (rental coverage on your credit card) or Option 3 (the CarmaCars Protection Plan). You can change this any time before pickup.
11. Choose the Booking type: Standard, or Non-refundable for 10% off with no refund.
12. Add anything we should know in the notes, for example a flight number.
13. Press **Continue to add-ons**. Step 4, Add-ons: tick what you want (see Add-ons below), then press **Review request**.

![](/guides/img/public-06-book-3-licence-desktop-22bb144e.jpg "desktop; size: 760 1452; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 9 61.8 11.2, 10 92.1 32.2, 11 92.1 50.4, 12 92.1 66.9, 13 71.7 97.0")

14. Step 5, Check it and send: read every line. Use Edit beside a line to change it.
15. Tick the box to confirm you are 18 or older and agree to the Terms of use and Privacy policy.
16. Press **Send request**. Nothing is charged and no card is needed.

![](/guides/img/public-07-book-4-review-desktop-005f4c0b.jpg "desktop; size: 760 492; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 14 92.1 24.8, 15 3.9 59.3, 16 73.7 89.0")

17. The confirmation shows your request number, for example CC-10021. Keep it for any question.
18. A person checks the calendar, your dates and your place, usually within 2 hours, day or night. Your offer arrives by email and in Trips.

![](/guides/img/public-08-book-5-sent-phone-14a99ccf.jpg "phone; size: 390 755; pins: 17 32.8 12.3")

## Add-ons

Extras for your trip, such as a baby seat, a child or booster seat, flowers waiting in the car, a chauffeur, an umbrella, a phone charger or a full tank of gas.

1. On the car page (under Add-ons) or in step 4 of the request, tick an add-on or use + and − for seats. The estimate shows the price at once.
2. Each add-on shows its price: a trip, a day (with the most for a trip) or an hour. HST is added.
3. Some need notice, for example flowers need 24 hours. Seats and other items show how many are left for your dates.
4. A chauffeur is confirmed by our team in your offer.

With a full tank of gas (prepaid) you can return the car at any fuel level, with no fuel charge.

## Ask in the chat

The chat button sits in the corner of every page.

1. Press it and write your question: a car, your dates, the price, how booking works. The CarmaCars assistant answers right away with prices from our booking system.
2. Want a person? Press **Talk to a person**. When our team is away, leave your name and email or phone with **Send my details** and tick "Email me a copy of this chat".
3. Press **End chat** when you are done. If you gave your email, a copy of the chat arrives by email.

A price in the chat is for the dates you asked. Nothing is booked until you approve an offer, sign and pay.
', 'Find a car and send a request', 'Search the fleet, pick dates and add-ons, and send a request in five short steps.',
  'Every booking starts as a request. A person checks the car and the price, then sends you an offer. Nothing is charged until you approve, sign and pay.

:::flow
Request | You pick a car and dates
Offer | We confirm the price
Sign | The rental agreement
Pay | Your card is authorized
Verify | Licence, selfie, coverage
Pick up | We hand over the keys
:::

## Find a car

Start on carmacars.ca. You do not need to sign in to look around.

1. Go to `carmacars.ca` and press **Find a car**.
2. Add your pickup and return dates. The list then shows the cars that are free and what the whole trip costs.
3. Narrow the list with Filters: type, seats, transmission and daily rate.
4. Open a car to see its photos, rates, what is included and its own calendar. Its car code (like CC-7F3A) is under the price: quote it when you call or chat with us, and we know the car at once.

![](/guides/img/public-02-cars-desktop-b6cd4fb8.jpg "desktop; size: 1440 880; address: carmacars.ca/cars; pins: 1 86.1 4.0, 2 11.1 56.8, 3 3.0 82.3, 4 34.0 87.5")

## Choose your dates on the car page

1. Under Dates and price, tap your pickup date, then your return date. Hatched days are already booked.
2. Choose the Pickup time and the Return time.
3. Want it brought to you? Tick **Deliver it to me** or **Pick it up from me at the end**. Open Add-ons to add a baby seat, flowers, a full tank and more.
4. Check Your estimate, then press **Request to book**. The add-ons you chose come with you.

![](/guides/img/public-03-car-page-desktop-73be4d63.jpg "desktop; size: 1120 760; address: carmacars.ca/cars/bmw-330i; pins: 1 24.4 39.7, 2 12.9 68.2, 3 3.0 76.2, 4 97.0 50.0")

> Watch out: A request does not hold the car. The car is booked only once you approve the offer, sign and pay.

## Send your request

The request has five short steps. Your answers are saved as you go, so you can come back.

1. Step 1, Dates and delivery: check the car and tap your dates in the calendar.
2. Set the Pickup time and Return time. Any time, day or night, with at least 2 hours of notice.
3. Your request, on the right, shows the estimated total as you go.

![](/guides/img/public-04-book-1-trip-desktop-63a3738b.jpg "desktop; size: 1440 1002; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 1 9.2 67.1, 2 15.3 91.0, 3 91.1 54.7")

4. Choose where you get the car: **At our location**, **Deliver it to an address** or **At the airport**. Then choose where you return it.
5. Press **Continue to driver details**.

![](/guides/img/public-04-book-1-trip-desktop-befba4f6.jpg "desktop; size: 760 942; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 4 5.3 26.2, 5 61.8 93.3")

6. Step 2, The driver: fill in your first and last name, email, mobile number and date of birth.
7. Someone else will drive too? Add them under Additional drivers. Each needs a G2 or G licence and signs the agreement.
8. Press **Continue to licence**.

![](/guides/img/public-05-book-2-driver-desktop-7b572499.jpg "desktop; size: 980 1032; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 6 30.6 21.1, 7 30.6 64.8, 8 55.6 88.0")

9. Step 3: choose your Licence class, for example Ontario G2.
10. Choose how the car is covered: Option 1 (OPCF 27 on your own auto policy), Option 2 (rental coverage on your credit card) or Option 3 (the CarmaCars Protection Plan). You can change this any time before pickup.
11. Choose the Booking type: Standard, or Non-refundable for 10% off with no refund.
12. Add anything we should know in the notes, for example a flight number.
13. Press **Continue to add-ons**. Step 4, Add-ons: tick what you want (see Add-ons below), then press **Review request**.

![](/guides/img/public-06-book-3-licence-desktop-22bb144e.jpg "desktop; size: 760 1452; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 9 61.8 11.2, 10 92.1 32.2, 11 92.1 50.4, 12 92.1 66.9, 13 71.7 97.0")

14. Step 5, Check it and send: read every line. Use Edit beside a line to change it.
15. Tick the box to confirm you are 18 or older and agree to the Terms of use and Privacy policy.
16. Press **Send request**. Nothing is charged and no card is needed.

![](/guides/img/public-07-book-4-review-desktop-005f4c0b.jpg "desktop; size: 760 492; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 14 92.1 24.8, 15 3.9 59.3, 16 73.7 89.0")

17. The confirmation shows your request number, for example CC-10021. Keep it for any question.
18. A person checks the calendar, your dates and your place, usually within 2 hours, day or night. Your offer arrives by email and in Trips.

![](/guides/img/public-08-book-5-sent-phone-14a99ccf.jpg "phone; size: 390 755; pins: 17 32.8 12.3")

## Add-ons

Extras for your trip, such as a baby seat, a child or booster seat, flowers waiting in the car, a chauffeur, an umbrella, a phone charger or a full tank of gas.

1. On the car page (under Add-ons) or in step 4 of the request, tick an add-on or use + and − for seats. The estimate shows the price at once.
2. Each add-on shows its price: a trip, a day (with the most for a trip) or an hour. HST is added.
3. Some need notice, for example flowers need 24 hours. Seats and other items show how many are left for your dates.
4. A chauffeur is confirmed by our team in your offer.

With a full tank of gas (prepaid) you can return the car at any fuel level, with no fuel charge.

## Ask in the chat

The chat button sits in the corner of every page.

1. Press it and write your question: a car, your dates, the price, how booking works. The CarmaCars assistant answers right away with prices from our booking system.
2. Want a person? Press **Talk to a person**. When our team is away, leave your name and email or phone with **Send my details** and tick "Email me a copy of this chat".
3. Press **End chat** when you are done. If you gave your email, a copy of the chat arrives by email.

A price in the chat is for the dates you asked. Nothing is booked until you approve an offer, sign and pay.
',
  '<p class="gd-p">Every booking starts as a request. A person checks the car and the price, then sends you an offer. Nothing is charged until you approve, sign and pay.</p><ol class="gd-flow"><li><b>1</b><span>Request</span><em>You pick a car and dates</em></li><li><b>2</b><span>Offer</span><em>We confirm the price</em></li><li><b>3</b><span>Sign</span><em>The rental agreement</em></li><li><b>4</b><span>Pay</span><em>Your card is authorized</em></li><li><b>5</b><span>Verify</span><em>Licence, selfie, coverage</em></li><li><b>6</b><span>Pick up</span><em>We hand over the keys</em></li></ol><section class="gd-task" id="find-a-car-and-send-a-request-find-a-car" data-gd-task><h2 class="gd-h2">Find a car</h2><p class="gd-p">Start on carmacars.ca. You do not need to sign in to look around.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Go to <span class="gd-url">carmacars.ca</span> and press <b class="gd-ui">Find a car</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Add your pickup and return dates. The list then shows the cars that are free and what the whole trip costs.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Narrow the list with Filters: type, seats, transmission and daily rate.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Open a car to see its photos, rates, what is included and its own calendar. Its car code (like CC-7F3A) is under the price: quote it when you call or chat with us, and we know the car at once.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/cars</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/880"><img src="/guides/img/public-02-cars-desktop-b6cd4fb8.jpg" alt="" loading="lazy" decoding="async" width="1440" height="880"><span class="gd-pin" style="left:86.1%;top:4%" aria-hidden="true">1</span><span class="gd-pin" style="left:11.1%;top:56.8%" aria-hidden="true">2</span><span class="gd-pin" style="left:3%;top:82.3%" aria-hidden="true">3</span><span class="gd-pin" style="left:34%;top:87.5%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="find-a-car-and-send-a-request-choose-your-dates-on-the-car-page" data-gd-task><h2 class="gd-h2">Choose your dates on the car page</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Under Dates and price, tap your pickup date, then your return date. Hatched days are already booked.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose the Pickup time and the Return time.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Want it brought to you? Tick <b class="gd-ui">Deliver it to me</b> or <b class="gd-ui">Pick it up from me at the end</b>. Open Add-ons to add a baby seat, flowers, a full tank and more.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Check Your estimate, then press <b class="gd-ui">Request to book</b>. The add-ons you chose come with you.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/cars/bmw-330i</span></div><div class="gd-imgwrap" style="aspect-ratio:1120/760"><img src="/guides/img/public-03-car-page-desktop-73be4d63.jpg" alt="" loading="lazy" decoding="async" width="1120" height="760"><span class="gd-pin" style="left:24.4%;top:39.7%" aria-hidden="true">1</span><span class="gd-pin" style="left:12.9%;top:68.2%" aria-hidden="true">2</span><span class="gd-pin" style="left:3%;top:76.2%" aria-hidden="true">3</span><span class="gd-pin" style="left:97%;top:50%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>A request does not hold the car. The car is booked only once you approve the offer, sign and pay.</div></aside></section><section class="gd-task" id="find-a-car-and-send-a-request-send-your-request" data-gd-task><h2 class="gd-h2">Send your request</h2><p class="gd-p">The request has five short steps. Your answers are saved as you go, so you can come back.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Step 1, Dates and delivery: check the car and tap your dates in the calendar.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Set the Pickup time and Return time. Any time, day or night, with at least 2 hours of notice.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Your request, on the right, shows the estimated total as you go.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/book/bmw-330i?from=2026-11-25&amp;to=2026-11-28&amp;tf=10:00&amp;tt=10:00</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1002"><img src="/guides/img/public-04-book-1-trip-desktop-63a3738b.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1002"><span class="gd-pin" style="left:9.2%;top:67.1%" aria-hidden="true">1</span><span class="gd-pin" style="left:15.3%;top:91%" aria-hidden="true">2</span><span class="gd-pin" style="left:91.1%;top:54.7%" aria-hidden="true">3</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="4"><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Choose where you get the car: <b class="gd-ui">At our location</b>, <b class="gd-ui">Deliver it to an address</b> or <b class="gd-ui">At the airport</b>. Then choose where you return it.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press <b class="gd-ui">Continue to driver details</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/book/bmw-330i?from=2026-11-25&amp;to=2026-11-28&amp;tf=10:00&amp;tt=10:00</span></div><div class="gd-imgwrap" style="aspect-ratio:760/942"><img src="/guides/img/public-04-book-1-trip-desktop-befba4f6.jpg" alt="" loading="lazy" decoding="async" width="760" height="942"><span class="gd-pin" style="left:5.3%;top:26.2%" aria-hidden="true">4</span><span class="gd-pin" style="left:61.8%;top:93.3%" aria-hidden="true">5</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="6"><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Step 2, The driver: fill in your first and last name, email, mobile number and date of birth.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Someone else will drive too? Add them under Additional drivers. Each needs a G2 or G licence and signs the agreement.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Press <b class="gd-ui">Continue to licence</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/book/bmw-330i?from=2026-11-25&amp;to=2026-11-28&amp;tf=10:00&amp;tt=10:00</span></div><div class="gd-imgwrap" style="aspect-ratio:980/1032"><img src="/guides/img/public-05-book-2-driver-desktop-7b572499.jpg" alt="" loading="lazy" decoding="async" width="980" height="1032"><span class="gd-pin" style="left:30.6%;top:21.1%" aria-hidden="true">6</span><span class="gd-pin" style="left:30.6%;top:64.8%" aria-hidden="true">7</span><span class="gd-pin" style="left:55.6%;top:88%" aria-hidden="true">8</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="9"><li><span class="gd-n" aria-hidden="true">9</span><div class="gd-t">Step 3: choose your Licence class, for example Ontario G2.</div></li><li><span class="gd-n" aria-hidden="true">10</span><div class="gd-t">Choose how the car is covered: Option 1 (OPCF 27 on your own auto policy), Option 2 (rental coverage on your credit card) or Option 3 (the CarmaCars Protection Plan). You can change this any time before pickup.</div></li><li><span class="gd-n" aria-hidden="true">11</span><div class="gd-t">Choose the Booking type: Standard, or Non-refundable for 10% off with no refund.</div></li><li><span class="gd-n" aria-hidden="true">12</span><div class="gd-t">Add anything we should know in the notes, for example a flight number.</div></li><li><span class="gd-n" aria-hidden="true">13</span><div class="gd-t">Press <b class="gd-ui">Continue to add-ons</b>. Step 4, Add-ons: tick what you want (see Add-ons below), then press <b class="gd-ui">Review request</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/book/bmw-330i?from=2026-11-25&amp;to=2026-11-28&amp;tf=10:00&amp;tt=10:00</span></div><div class="gd-imgwrap" style="aspect-ratio:760/1452"><img src="/guides/img/public-06-book-3-licence-desktop-22bb144e.jpg" alt="" loading="lazy" decoding="async" width="760" height="1452"><span class="gd-pin" style="left:61.8%;top:11.2%" aria-hidden="true">9</span><span class="gd-pin" style="left:92.1%;top:32.2%" aria-hidden="true">10</span><span class="gd-pin" style="left:92.1%;top:50.4%" aria-hidden="true">11</span><span class="gd-pin" style="left:92.1%;top:66.9%" aria-hidden="true">12</span><span class="gd-pin" style="left:71.7%;top:97%" aria-hidden="true">13</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="14"><li><span class="gd-n" aria-hidden="true">14</span><div class="gd-t">Step 5, Check it and send: read every line. Use Edit beside a line to change it.</div></li><li><span class="gd-n" aria-hidden="true">15</span><div class="gd-t">Tick the box to confirm you are 18 or older and agree to the Terms of use and Privacy policy.</div></li><li><span class="gd-n" aria-hidden="true">16</span><div class="gd-t">Press <b class="gd-ui">Send request</b>. Nothing is charged and no card is needed.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/book/bmw-330i?from=2026-11-25&amp;to=2026-11-28&amp;tf=10:00&amp;tt=10:00</span></div><div class="gd-imgwrap" style="aspect-ratio:760/492"><img src="/guides/img/public-07-book-4-review-desktop-005f4c0b.jpg" alt="" loading="lazy" decoding="async" width="760" height="492"><span class="gd-pin" style="left:92.1%;top:24.8%" aria-hidden="true">14</span><span class="gd-pin" style="left:3.9%;top:59.3%" aria-hidden="true">15</span><span class="gd-pin" style="left:73.7%;top:89%" aria-hidden="true">16</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol" start="17"><li><span class="gd-n" aria-hidden="true">17</span><div class="gd-t">The confirmation shows your request number, for example CC-10021. Keep it for any question.</div></li><li><span class="gd-n" aria-hidden="true">18</span><div class="gd-t">A person checks the calendar, your dates and your place, usually within 2 hours, day or night. Your offer arrives by email and in Trips.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/755"><img src="/guides/img/public-08-book-5-sent-phone-14a99ccf.jpg" alt="" loading="lazy" decoding="async" width="390" height="755"><span class="gd-pin" style="left:32.8%;top:12.3%" aria-hidden="true">17</span></div></div></figure></div></section><section class="gd-task" id="find-a-car-and-send-a-request-add-ons" data-gd-task><h2 class="gd-h2">Add-ons</h2><p class="gd-p">Extras for your trip, such as a baby seat, a child or booster seat, flowers waiting in the car, a chauffeur, an umbrella, a phone charger or a full tank of gas.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On the car page (under Add-ons) or in step 4 of the request, tick an add-on or use + and − for seats. The estimate shows the price at once.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each add-on shows its price: a trip, a day (with the most for a trip) or an hour. HST is added.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Some need notice, for example flowers need 24 hours. Seats and other items show how many are left for your dates.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A chauffeur is confirmed by our team in your offer.</div></li></ol></div><p class="gd-p">With a full tank of gas (prepaid) you can return the car at any fuel level, with no fuel charge.</p></section><section class="gd-task" id="find-a-car-and-send-a-request-ask-in-the-chat" data-gd-task><h2 class="gd-h2">Ask in the chat</h2><p class="gd-p">The chat button sits in the corner of every page.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press it and write your question: a car, your dates, the price, how booking works. The CarmaCars assistant answers right away with prices from our booking system.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Want a person? Press <b class="gd-ui">Talk to a person</b>. When our team is away, leave your name and email or phone with <b class="gd-ui">Send my details</b> and tick &quot;Email me a copy of this chat&quot;.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">End chat</b> when you are done. If you gave your email, a copy of the chat arrives by email.</div></li></ol></div><p class="gd-p">A price in the chat is for the dates you asked. Nothing is booked until you approve an offer, sign and pay.</p></section>');
select app.guide_release_section('renter', 'before-pickup', 'chapter', 'sign-and-pay', 'Your booking is confirmed. A few things are left: your licence photos, a selfie and proof of coverage, a signature from each additional driver, and the deposit.

## Your booking page

1. Open **Trips**, then your booking. The status is at the top, for example Confirmed.
2. The red card tells you what is still needed before pickup.
3. Progress shows each stage, from Request sent to Statement.
4. Need something else? holds **Licence and coverage**, **Ask to change dates**, **Cancel booking** and **Extend**.

![](/guides/img/renter-08-booking-confirmed-desktop-125011fd.jpg "desktop; size: 1440 1032; address: carmacars.ca/account/bookings/CC-10057; pins: 1 15.6 9.1, 2 18.1 36.5, 3 8.1 56.8, 4 96.5 79.9")

## Upload your licence, selfie and coverage

Do this at least 24 hours before pickup. It takes a few minutes with your phone.

1. On your booking, press **Upload documents** (or **Licence and coverage**).
2. Licence, front: lay the licence on a dark surface with all four corners visible. Press **Take photo**.
3. Licence, back: do the same for the back.
4. Selfie with your licence: hold the licence beside your face, then press **Take selfie**.
5. Coverage for damage to the car: add what your option asks for, then press **Upload proof**.

![](/guides/img/renter-09-verify-desktop-d20f668d.jpg "desktop; size: 1440 1232; address: carmacars.ca/account/bookings/CC-10057/verify; pins: 2 18.5 65.3, 3 50.0 63.6, 4 81.2 63.6, 5 50.0 95.3")

> Tip: For Option 1, add the policy page or insurer letter that shows OPCF 27. For Option 2 (your credit card coverage), add the card issuer, the last four digits and the card benefits certificate; it must be the card you paid with. For Option 3, we send the Protection Plan''s terms and activate it once it is paid. We delete licence and face photos 90 days after your rental ends.

## Additional drivers

Each additional driver signs the agreement with their own link.

1. When the agreement is ready, each driver with an email gets their own signing link.
2. On your booking, press **Copy their signing link** to send it yourself, or **Send a new link**.
3. Each driver adds their own licence photos and selfie, like you did.

> Watch out: Signing links expire after 72 hours. A new link ends the older one, so always send the newest.

## Add something to your trip

Until 24 hours before pickup (or the notice an add-on needs), add add-ons from your booking.

1. On your booking, under Add-ons, press **Add something to your trip**.
2. Tick the add-on you want. Its price shows below.
3. Press **Add and pay**. It is charged at once on the card you paid with, and shows on your booking and receipt.
4. A chauffeur needs our confirmation: press **Ask for it**. We confirm it and charge your card then.

> Tip: If you cancel, add-ons are refunded like the rest of your booking. Flowers and a chauffeur are not refunded once their notice before pickup has started.

## What to bring to pickup

- Your original licence. A photo is not enough.
- The card you paid with. The deposit is taken on it about an hour before pickup.
- A few minutes to walk around the car with us. We photograph it together.
', 'Before pickup', 'Upload your licence and coverage, send driver links, and know what to bring.',
  'Your booking is confirmed. A few things are left: your licence photos, a selfie and proof of coverage, a signature from each additional driver, and the deposit.

## Your booking page

1. Open **Trips**, then your booking. The status is at the top, for example Confirmed.
2. The red card tells you what is still needed before pickup.
3. Progress shows each stage, from Request sent to Statement.
4. Need something else? holds **Licence and coverage**, **Ask to change dates**, **Cancel booking** and **Extend**.

![](/guides/img/renter-08-booking-confirmed-desktop-125011fd.jpg "desktop; size: 1440 1032; address: carmacars.ca/account/bookings/CC-10057; pins: 1 15.6 9.1, 2 18.1 36.5, 3 8.1 56.8, 4 96.5 79.9")

## Upload your licence, selfie and coverage

Do this at least 24 hours before pickup. It takes a few minutes with your phone.

1. On your booking, press **Upload documents** (or **Licence and coverage**).
2. Licence, front: lay the licence on a dark surface with all four corners visible. Press **Take photo**.
3. Licence, back: do the same for the back.
4. Selfie with your licence: hold the licence beside your face, then press **Take selfie**.
5. Coverage for damage to the car: add what your option asks for, then press **Upload proof**.

![](/guides/img/renter-09-verify-desktop-d20f668d.jpg "desktop; size: 1440 1232; address: carmacars.ca/account/bookings/CC-10057/verify; pins: 2 18.5 65.3, 3 50.0 63.6, 4 81.2 63.6, 5 50.0 95.3")

| Your option | What we need |
| --- | --- |
| Option 1, OPCF 27 on your own policy | Your insurer, the policy number and its expiry (after your return date), and the policy or endorsement that shows OPCF 27, as a PDF or photos (up to 6 pages). |
| Option 2, your credit card''s rental coverage | Pay with that card: it must be a credit card (debit and prepaid cards are refused) in your name. Tick that it covers this kind of car for this many days. The card''s benefits document is optional. |
| Option 3, the CarmaCars Protection Plan | Ask for it on your booking; we confirm it once it is active. |

> Tip: A person checks your proof and approves it, or tells you what to fix. The car is handed over only once it is approved. Changing your option replaces the earlier proof. We remind you 48 and 24 hours before pickup while it is missing. We delete licence and face photos 90 days after your rental ends.

## Additional drivers

Each additional driver signs the agreement with their own link.

1. When the agreement is ready, each driver with an email gets their own signing link.
2. On your booking, press **Copy their signing link** to send it yourself, or **Send a new link**.
3. Each driver adds their own licence photos and selfie, like you did.

> Watch out: Signing links expire after 72 hours. A new link ends the older one, so always send the newest.

## Add something to your trip

Until 24 hours before pickup (or the notice an add-on needs), add add-ons from your booking.

1. On your booking, under Add-ons, press **Add something to your trip**.
2. Tick the add-on you want. Its price shows below.
3. Press **Add and pay**. It is charged at once on the card you paid with, and shows on your booking and receipt.
4. A chauffeur needs our confirmation: press **Ask for it**. We confirm it and charge your card then.

No card on file for this booking? The add-on is added and waits for payment: press **Pay for your add-ons** under Add-ons, enter a card and press **Pay**. It is charged at once; that card is not kept.

> Tip: If you cancel, add-ons are refunded like the rest of your booking. Flowers and a chauffeur are not refunded once their notice before pickup has started.

## What to bring to pickup

- Your original licence. A photo is not enough.
- The card you paid with. The deposit is taken on it about an hour before pickup.
- A few minutes to walk around the car with us. We photograph it together.
',
  '<p class="gd-p">Your booking is confirmed. A few things are left: your licence photos, a selfie and proof of coverage, a signature from each additional driver, and the deposit.</p><section class="gd-task" id="before-pickup-your-booking-page" data-gd-task><h2 class="gd-h2">Your booking page</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Trips</b>, then your booking. The status is at the top, for example Confirmed.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The red card tells you what is still needed before pickup.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Progress shows each stage, from Request sent to Statement.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Need something else? holds <b class="gd-ui">Licence and coverage</b>, <b class="gd-ui">Ask to change dates</b>, <b class="gd-ui">Cancel booking</b> and <b class="gd-ui">Extend</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/account/bookings/CC-10057</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1032"><img src="/guides/img/renter-08-booking-confirmed-desktop-125011fd.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1032"><span class="gd-pin" style="left:15.6%;top:9.1%" aria-hidden="true">1</span><span class="gd-pin" style="left:18.1%;top:36.5%" aria-hidden="true">2</span><span class="gd-pin" style="left:8.1%;top:56.8%" aria-hidden="true">3</span><span class="gd-pin" style="left:96.5%;top:79.9%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="before-pickup-upload-your-licence-selfie-and-coverage" data-gd-task><h2 class="gd-h2">Upload your licence, selfie and coverage</h2><p class="gd-p">Do this at least 24 hours before pickup. It takes a few minutes with your phone.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On your booking, press <b class="gd-ui">Upload documents</b> (or <b class="gd-ui">Licence and coverage</b>).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Licence, front: lay the licence on a dark surface with all four corners visible. Press <b class="gd-ui">Take photo</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Licence, back: do the same for the back.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Selfie with your licence: hold the licence beside your face, then press <b class="gd-ui">Take selfie</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Coverage for damage to the car: add what your option asks for, then press <b class="gd-ui">Upload proof</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/account/bookings/CC-10057/verify</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1232"><img src="/guides/img/renter-09-verify-desktop-d20f668d.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1232"><span class="gd-pin" style="left:18.5%;top:65.3%" aria-hidden="true">2</span><span class="gd-pin" style="left:50%;top:63.6%" aria-hidden="true">3</span><span class="gd-pin" style="left:81.2%;top:63.6%" aria-hidden="true">4</span><span class="gd-pin" style="left:50%;top:95.3%" aria-hidden="true">5</span></div></div></figure></div><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Your option</th><th scope="col">What we need</th></tr></thead><tbody><tr><td>Option 1, OPCF 27 on your own policy</td><td>Your insurer, the policy number and its expiry (after your return date), and the policy or endorsement that shows OPCF 27, as a PDF or photos (up to 6 pages).</td></tr><tr><td>Option 2, your credit card&#39;s rental coverage</td><td>Pay with that card: it must be a credit card (debit and prepaid cards are refused) in your name. Tick that it covers this kind of car for this many days. The card&#39;s benefits document is optional.</td></tr><tr><td>Option 3, the CarmaCars Protection Plan</td><td>Ask for it on your booking; we confirm it once it is active.</td></tr></tbody></table></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A person checks your proof and approves it, or tells you what to fix. The car is handed over only once it is approved. Changing your option replaces the earlier proof. We remind you 48 and 24 hours before pickup while it is missing. We delete licence and face photos 90 days after your rental ends.</div></aside></section><section class="gd-task" id="before-pickup-additional-drivers" data-gd-task><h2 class="gd-h2">Additional drivers</h2><p class="gd-p">Each additional driver signs the agreement with their own link.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">When the agreement is ready, each driver with an email gets their own signing link.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">On your booking, press <b class="gd-ui">Copy their signing link</b> to send it yourself, or <b class="gd-ui">Send a new link</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Each driver adds their own licence photos and selfie, like you did.</div></li></ol></div><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>Signing links expire after 72 hours. A new link ends the older one, so always send the newest.</div></aside></section><section class="gd-task" id="before-pickup-add-something-to-your-trip" data-gd-task><h2 class="gd-h2">Add something to your trip</h2><p class="gd-p">Until 24 hours before pickup (or the notice an add-on needs), add add-ons from your booking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On your booking, under Add-ons, press <b class="gd-ui">Add something to your trip</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Tick the add-on you want. Its price shows below.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Add and pay</b>. It is charged at once on the card you paid with, and shows on your booking and receipt.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A chauffeur needs our confirmation: press <b class="gd-ui">Ask for it</b>. We confirm it and charge your card then.</div></li></ol></div><p class="gd-p">No card on file for this booking? The add-on is added and waits for payment: press <b class="gd-ui">Pay for your add-ons</b> under Add-ons, enter a card and press <b class="gd-ui">Pay</b>. It is charged at once; that card is not kept.</p><aside class="gd-box"><span class="gd-lbl">Tip</span><div>If you cancel, add-ons are refunded like the rest of your booking. Flowers and a chauffeur are not refunded once their notice before pickup has started.</div></aside></section><section class="gd-task" id="before-pickup-what-to-bring-to-pickup" data-gd-task><h2 class="gd-h2">What to bring to pickup</h2><ul class="gd-ul"><li>Your original licence. A photo is not enough.</li><li>The card you paid with. The deposit is taken on it about an hour before pickup.</li><li>A few minutes to walk around the car with us. We photograph it together.</li></ul></section>');
select app.guide_release_section('owner', 'apply-and-get-your-car-listed', 'chapter', 'start-here', 'You apply online in about ten minutes. We reply within one business day, set your terms, and walk you through the rest.

## Apply to list your car

1. Go to `carmacars.ca/list-your-car` and press **Apply to list your car**.
2. About you: individual or corporation, your address, licence and date of birth. Press **Continue to vehicles**.
3. For each car, type the VIN and press **Look up**. Use **Add another vehicle** for more cars.
4. Read how it will work, press **Continue**, then **Review**.
5. Press **Submit application**, then **Go to your owner portal**.

![](/guides/img/public-13-list-your-car-desktop-48bf4cb0.jpg "desktop; size: 1440 800; address: carmacars.ca/list-your-car; pins: 1 20.1 74.9")

> Tip: Need a break? **Email me a link** saves your application and sends you a link to finish later.

## What happens next

Five steps take your car from your driveway to its first rental.

:::flow
Tell us about the car | We confirm fees and set your terms
Sign the agreements | Online, one for all your cars
One registry visit | We fill in the forms and come with you
Tracker and insurance | We install it and add the car
Photos and listing | Live within 1 business day
:::

1. When your terms are ready, Home shows **Check and sign**. Everything is filled in from your application: check the short list of key values (each has a **Fix** link) and open any document to read it in full.
2. Tap **All of these** for the three confirmations (your initials are filled in), then press **Sign all**. Your name on file is your signature; prefer to draw it? Press **Draw instead**. One signature covers every document, in about a minute.
3. Pay the upfront invoice: the first and last month''s insurance fee for each car (see chapter 4).
4. Upload what each car''s checklist asks for: the ownership permit, the lender''s permission if it is financed or leased, and insurance.
5. Sign Forms C and D (filled in for you) with witnesses: Form C on screen with your witness beside you, or on paper; Form D on paper, with a photo of each page from your phone (see chapter 5).

## If we need a little more

Sometimes we need one more document before we can approve your application, for example the ownership permit or the insurance slip.

1. You get an email, and Home shows "We need a little more" with the list and any note from our team.
2. Upload what is asked, or write Your answer, and press **Send my answer**.
3. We review it within 1 business day. Once we approve your application, you get an email and Home shows Check and sign.
', 'Apply and get your car listed', 'Apply online, sign, pay the upfront invoice and get your car on the site.',
  'You apply online in about ten minutes. We reply within one business day, set your terms, and walk you through the rest.

## Apply to list your car

1. Go to `carmacars.ca/list-your-car` and press **Apply to list your car**.
2. About you: individual or corporation, your address, licence and date of birth. Press **Continue to vehicles**.
3. For each car, type the VIN: your car is found as you type the last character (Edit if anything is wrong), then tap its colour and answer the rest. Use **Add another vehicle** for more cars.
4. Read how it will work, press **Continue**, then **Review**.
5. Press **Submit application**, then **Go to your owner portal**.

![](/guides/img/public-13-list-your-car-desktop-48bf4cb0.jpg "desktop; size: 1440 800; address: carmacars.ca/list-your-car; pins: 1 20.1 74.9")

> Tip: Need a break? **Email me a link** saves your application and sends you a link to finish later.

> Good to know: No car to add yet? On the vehicle step press **I''ll add my car later**, choose your password and press **Open my owner account**. Your owner portal opens with **Add your first car**: press it when you are ready, starting with the VIN.

## What happens next

Five steps take your car from your driveway to its first rental.

:::flow
Tell us about the car | We confirm fees and set your terms
Sign the agreements | Online, one for all your cars
One registry visit | We fill in the forms and come with you
Tracker and insurance | We install it and add the car
Photos and listing | Live within 1 business day
:::

1. When your terms are ready, Home shows **Check and sign**. Everything is filled in from your application: check the short list of key values (each has a **Fix** link) and open any document to read it in full.
2. Tap **All of these** for the three confirmations (your initials are filled in), then press **Sign all**. Your name on file is your signature; prefer to draw it? Press **Draw instead**. One signature covers every document, in about a minute.
3. Pay the upfront invoice: the first and last month''s insurance fee for each car (see chapter 4).
4. Upload what each car''s checklist asks for: the ownership permit, the lender''s permission if it is financed or leased, and insurance.
5. Sign Forms C and D (filled in for you) with witnesses: Form C on screen with your witness beside you, or on paper; Form D on paper, with a photo of each page from your phone (see chapter 5).

## If we need a little more

Sometimes we need one more document before we can approve your application, for example the ownership permit or the insurance slip.

1. You get an email, and Home shows "We need a little more" with the list and any note from our team.
2. Upload what is asked, or write Your answer, and press **Send my answer**.
3. We review it within 1 business day. Once we approve your application, you get an email and Home shows Check and sign.
',
  '<p class="gd-p">You apply online in about ten minutes. We reply within one business day, set your terms, and walk you through the rest.</p><section class="gd-task" id="apply-and-get-your-car-listed-apply-to-list-your-car" data-gd-task><h2 class="gd-h2">Apply to list your car</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Go to <span class="gd-url">carmacars.ca/list-your-car</span> and press <b class="gd-ui">Apply to list your car</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">About you: individual or corporation, your address, licence and date of birth. Press <b class="gd-ui">Continue to vehicles</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">For each car, type the VIN: your car is found as you type the last character (Edit if anything is wrong), then tap its colour and answer the rest. Use <b class="gd-ui">Add another vehicle</b> for more cars.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Read how it will work, press <b class="gd-ui">Continue</b>, then <b class="gd-ui">Review</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press <b class="gd-ui">Submit application</b>, then <b class="gd-ui">Go to your owner portal</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/list-your-car</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/800"><img src="/guides/img/public-13-list-your-car-desktop-48bf4cb0.jpg" alt="" loading="lazy" decoding="async" width="1440" height="800"><span class="gd-pin" style="left:20.1%;top:74.9%" aria-hidden="true">1</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Need a break? <b class="gd-ui">Email me a link</b> saves your application and sends you a link to finish later.</div></aside><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>No car to add yet? On the vehicle step press <b class="gd-ui">I&#39;ll add my car later</b>, choose your password and press <b class="gd-ui">Open my owner account</b>. Your owner portal opens with <b class="gd-ui">Add your first car</b>: press it when you are ready, starting with the VIN.</div></aside></section><section class="gd-task" id="apply-and-get-your-car-listed-what-happens-next" data-gd-task><h2 class="gd-h2">What happens next</h2><p class="gd-p">Five steps take your car from your driveway to its first rental.</p><ol class="gd-flow"><li><b>1</b><span>Tell us about the car</span><em>We confirm fees and set your terms</em></li><li><b>2</b><span>Sign the agreements</span><em>Online, one for all your cars</em></li><li><b>3</b><span>One registry visit</span><em>We fill in the forms and come with you</em></li><li><b>4</b><span>Tracker and insurance</span><em>We install it and add the car</em></li><li><b>5</b><span>Photos and listing</span><em>Live within 1 business day</em></li></ol><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">When your terms are ready, Home shows <b class="gd-ui">Check and sign</b>. Everything is filled in from your application: check the short list of key values (each has a <b class="gd-ui">Fix</b> link) and open any document to read it in full.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Tap <b class="gd-ui">All of these</b> for the three confirmations (your initials are filled in), then press <b class="gd-ui">Sign all</b>. Your name on file is your signature; prefer to draw it? Press <b class="gd-ui">Draw instead</b>. One signature covers every document, in about a minute.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Pay the upfront invoice: the first and last month&#39;s insurance fee for each car (see chapter 4).</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Upload what each car&#39;s checklist asks for: the ownership permit, the lender&#39;s permission if it is financed or leased, and insurance.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Sign Forms C and D (filled in for you) with witnesses: Form C on screen with your witness beside you, or on paper; Form D on paper, with a photo of each page from your phone (see chapter 5).</div></li></ol></div></section><section class="gd-task" id="apply-and-get-your-car-listed-if-we-need-a-little-more" data-gd-task><h2 class="gd-h2">If we need a little more</h2><p class="gd-p">Sometimes we need one more document before we can approve your application, for example the ownership permit or the insurance slip.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">You get an email, and Home shows &quot;We need a little more&quot; with the list and any note from our team.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Upload what is asked, or write Your answer, and press <b class="gd-ui">Send my answer</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">We review it within 1 business day. Once we approve your application, you get an email and Home shows Check and sign.</div></li></ol></div></section>');
select app.guide_release_section('admin', 'getting-around-admin', 'chapter', 'start-here', 'Admin opens on To do: what needs you now, most urgent first. The menu groups every screen into seven groups: Today, Bookings, Cars, Owners and partners, Money, People and Settings. Search finds any booking, car or person.

## To do

Start every shift here. Each line counts what is waiting and has one button to deal with it.

1. The list is in order of urgency: owner applications, booking requests, changes renters asked for, failed payments, agreements to countersign, tolls, listings, plates not checked, insurance, cars using sample photos, staff commissions to approve and to pay, prices typed by hand to review, and staff who say they sourced a website request.
2. Press the button on a line to go straight to that work. A line with nothing waiting moves to the bottom, under "more with nothing waiting".
3. Below the list: today''s pickups (ready or not ready) and today''s returns (due or late).
4. Press **Overview** for the money, fleet and queue figures, the alerts and the team''s sales for the month.

![](/guides/img/admin-01-today-desktop-ea48309c.jpg "desktop; size: 1440 900; address: carmacars.ca/admin; pins: 1 22.6 31.6, 2 90.3 31.7, 3 18.4 90.2, 4 94.4 22.2")

## The menu

The current group is open, with its pages; press another group to open it. On a phone the whole menu sits behind one Menu button that says where you are.

| Group | Pages |
| --- | --- |
| Today | To do, Overview, Tasks |
| Bookings | Requests, Bookings, Calendar, Add a rental, Damage, Incidents and claims, Reviews |
| Cars | Vehicles, Listings, Similar cars, Retire or delete, Rates for many cars |
| Owners and partners | Applications, Owners, Add a car for an owner, Partners, Owner forms, Paid and signed |
| Money | Owner invoices, Owner debits, Payments and refunds, Owner statements, Company statements, Payouts, Staff commissions, Tolls and tickets, Insurer invoices, Reconciliation, Expenses |
| People | Renters, Staff, Investors, Portals and view as |
| Settings | All settings, Site, Program, Forms, Guides, Emails, Email log, Sample photos, Audit log |

![On a phone: press Menu (1), then a group (2), then the page (3).](/guides/img/admin-31-menu-phone-667dc2fd.jpg "phone; size: 390 715; pins: 1 10.3 28.7, 2 76.9 42.4, 3 76.9 48.3")

## Search

The search box sits at the top of the menu, on every page.

1. Type a booking number (CC-1042), a plate, a VIN, or a name or email address.
2. Press **Search** (or Enter). Results come in groups: bookings, cars, owners, partners and renters. Open one to go to its page.

![](/guides/img/admin-32-search-desktop-ca548a70.jpg "desktop; size: 1440 420; address: carmacars.ca/admin/search?q=CC-10057; pins: 1 7.4 45.2, 2 95.0 46.9")

## Keyboard shortcuts

Press g, then a letter. Press / to jump to the search box.

| Keys | Opens | Keys | Opens |
| --- | --- | --- | --- |
| g t | To do | g v | Vehicles |
| g r | Requests | g l | Listings |
| g b | Bookings | g a | Applications |
| g c | Calendar | g o | Owners |
| g k | Tasks | g m | Payments and refunds |
| g s | All settings | / | Search |
', 'Getting around Admin', 'To do, the menu, search, keyboard shortcuts and your other portals.',
  'Admin opens on To do: what needs you now, most urgent first. The menu groups every screen into seven groups: Today, Bookings, Cars, Owners and partners, Money, People and Settings. Search finds any booking, car or person.

## To do

Start every shift here. Each line says what to do and why, and its button opens a small pop-up that does it, already filled in. Nothing to remember and no menu to search.

1. Each piece of work is its own line, marked Now, Today or When you can: a car the insurer has not confirmed, a car not on the site, a renter''s documents to check, a visitor waiting in live chat, a booking request, a change a renter asked for, an owner application, an owner invoice waiting for payment, the first and last month an owner paid after their invoices were voided, the terms agreed with an owner still on the standard grid, documents an owner has not signed, an official form to check, a plate to check, a car showing sample photos, and any task of the Admin.
2. Press the line''s button: Mark insured, Set rates and publish, Review documents, Record payment, Record what they paid, Enter the terms, Record paper signature, Checked: use for owners, Open the chat, and so on. A line you do not need has Not needed or These are correct. The pop-up is filled in; check it and confirm. The line disappears once the work is done.
3. Under the lines, the counts with one button each (failed payments, agreements to countersign, tolls, listings, insurance, staff commissions, prices typed by hand, sales claims, Turo emails). A count with nothing waiting moves to the bottom, under "more with nothing waiting".
4. While no assistant holds customer service, sales, finance or fleet (the live verification''s test accounts do not count), their tasks come to To do too, and so do their emails, to rent@carmacars.ca.
5. Below the list: today''s pickups (ready or not ready) and today''s returns (due or late).
6. Press **Overview** for the money, fleet and queue figures, the alerts and the team''s sales for the month.

![](/guides/img/admin-01-today-desktop-ea48309c.jpg "desktop; size: 1440 900; address: carmacars.ca/admin; pins: 1 22.6 31.6, 2 90.3 31.7, 3 18.4 90.2, 4 94.4 22.2")

## The menu

The current group is open, with its pages; press another group to open it. On a phone the whole menu sits behind one Menu button that says where you are.

| Group | Pages |
| --- | --- |
| Today | To do, Overview, Tasks |
| Bookings | Requests, Bookings, Calendar, Add a rental, Damage, Incidents and claims, Reviews |
| Cars | Vehicles, Listings, Similar cars, Retire or delete, Rates for many cars |
| Owners and partners | Applications, Owners, Add a car for an owner, Partners, Owner forms, Paid and signed |
| Money | Owner invoices, Owner debits, Payments and refunds, Owner statements, Company statements, Payouts, Staff commissions, Tolls and tickets, Insurer invoices, Reconciliation, Expenses |
| People | Renters, Staff, Investors, Portals and view as |
| Settings | All settings, Site, Program, Forms, Guides, Emails, Email log, Sample photos, Audit log |

![On a phone: press Menu (1), then a group (2), then the page (3).](/guides/img/admin-31-menu-phone-667dc2fd.jpg "phone; size: 390 715; pins: 1 10.3 28.7, 2 76.9 42.4, 3 76.9 48.3")

## Search

The search box sits at the top of the menu, on every page.

1. Type a booking number (CC-1042), a car code (CC-7F3A, on every car page and fleet card), a plate, a VIN, or a name or email address.
2. Press **Search** (or Enter). Results come in groups: bookings, cars, owners, partners and renters. Open one to go to its page.

![](/guides/img/admin-32-search-desktop-ca548a70.jpg "desktop; size: 1440 420; address: carmacars.ca/admin/search?q=CC-10057; pins: 1 7.4 45.2, 2 95.0 46.9")

## Keyboard shortcuts

Press g, then a letter. Press / to jump to the search box.

| Keys | Opens | Keys | Opens |
| --- | --- | --- | --- |
| g t | To do | g v | Vehicles |
| g r | Requests | g l | Listings |
| g b | Bookings | g a | Applications |
| g c | Calendar | g o | Owners |
| g k | Tasks | g m | Payments and refunds |
| g s | All settings | / | Search |
',
  '<p class="gd-p">Admin opens on To do: what needs you now, most urgent first. The menu groups every screen into seven groups: Today, Bookings, Cars, Owners and partners, Money, People and Settings. Search finds any booking, car or person.</p><section class="gd-task" id="getting-around-admin-to-do" data-gd-task><h2 class="gd-h2">To do</h2><p class="gd-p">Start every shift here. Each line says what to do and why, and its button opens a small pop-up that does it, already filled in. Nothing to remember and no menu to search.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each piece of work is its own line, marked Now, Today or When you can: a car the insurer has not confirmed, a car not on the site, a renter&#39;s documents to check, a visitor waiting in live chat, a booking request, a change a renter asked for, an owner application, an owner invoice waiting for payment, the first and last month an owner paid after their invoices were voided, the terms agreed with an owner still on the standard grid, documents an owner has not signed, an official form to check, a plate to check, a car showing sample photos, and any task of the Admin.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press the line&#39;s button: Mark insured, Set rates and publish, Review documents, Record payment, Record what they paid, Enter the terms, Record paper signature, Checked: use for owners, Open the chat, and so on. A line you do not need has Not needed or These are correct. The pop-up is filled in; check it and confirm. The line disappears once the work is done.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Under the lines, the counts with one button each (failed payments, agreements to countersign, tolls, listings, insurance, staff commissions, prices typed by hand, sales claims, Turo emails). A count with nothing waiting moves to the bottom, under &quot;more with nothing waiting&quot;.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">While no assistant holds customer service, sales, finance or fleet (the live verification&#39;s test accounts do not count), their tasks come to To do too, and so do their emails, to rent@carmacars.ca.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Below the list: today&#39;s pickups (ready or not ready) and today&#39;s returns (due or late).</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Press <b class="gd-ui">Overview</b> for the money, fleet and queue figures, the alerts and the team&#39;s sales for the month.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/900"><img src="/guides/img/admin-01-today-desktop-ea48309c.jpg" alt="" loading="lazy" decoding="async" width="1440" height="900"><span class="gd-pin" style="left:22.6%;top:31.6%" aria-hidden="true">1</span><span class="gd-pin" style="left:90.3%;top:31.7%" aria-hidden="true">2</span><span class="gd-pin" style="left:18.4%;top:90.2%" aria-hidden="true">3</span><span class="gd-pin" style="left:94.4%;top:22.2%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="getting-around-admin-the-menu" data-gd-task><h2 class="gd-h2">The menu</h2><p class="gd-p">The current group is open, with its pages; press another group to open it. On a phone the whole menu sits behind one Menu button that says where you are.</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Group</th><th scope="col">Pages</th></tr></thead><tbody><tr><td>Today</td><td>To do, Overview, Tasks</td></tr><tr><td>Bookings</td><td>Requests, Bookings, Calendar, Add a rental, Damage, Incidents and claims, Reviews</td></tr><tr><td>Cars</td><td>Vehicles, Listings, Similar cars, Retire or delete, Rates for many cars</td></tr><tr><td>Owners and partners</td><td>Applications, Owners, Add a car for an owner, Partners, Owner forms, Paid and signed</td></tr><tr><td>Money</td><td>Owner invoices, Owner debits, Payments and refunds, Owner statements, Company statements, Payouts, Staff commissions, Tolls and tickets, Insurer invoices, Reconciliation, Expenses</td></tr><tr><td>People</td><td>Renters, Staff, Investors, Portals and view as</td></tr><tr><td>Settings</td><td>All settings, Site, Program, Forms, Guides, Emails, Email log, Sample photos, Audit log</td></tr></tbody></table></div><div class="gd-figblock"><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/715"><img src="/guides/img/admin-31-menu-phone-667dc2fd.jpg" alt="On a phone: press Menu (1), then a group (2), then the page (3)." loading="lazy" decoding="async" width="390" height="715"><span class="gd-pin" style="left:10.3%;top:28.7%" aria-hidden="true">1</span><span class="gd-pin" style="left:76.9%;top:42.4%" aria-hidden="true">2</span><span class="gd-pin" style="left:76.9%;top:48.3%" aria-hidden="true">3</span></div></div><figcaption>On a phone: press Menu (1), then a group (2), then the page (3).</figcaption></figure></div></section><section class="gd-task" id="getting-around-admin-search" data-gd-task><h2 class="gd-h2">Search</h2><p class="gd-p">The search box sits at the top of the menu, on every page.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Type a booking number (CC-1042), a car code (CC-7F3A, on every car page and fleet card), a plate, a VIN, or a name or email address.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Search</b> (or Enter). Results come in groups: bookings, cars, owners, partners and renters. Open one to go to its page.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/search?q=CC-10057</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/420"><img src="/guides/img/admin-32-search-desktop-ca548a70.jpg" alt="" loading="lazy" decoding="async" width="1440" height="420"><span class="gd-pin" style="left:7.4%;top:45.2%" aria-hidden="true">1</span><span class="gd-pin" style="left:95%;top:46.9%" aria-hidden="true">2</span></div></div></figure></div></section><section class="gd-task" id="getting-around-admin-keyboard-shortcuts" data-gd-task><h2 class="gd-h2">Keyboard shortcuts</h2><p class="gd-p">Press g, then a letter. Press / to jump to the search box.</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Keys</th><th scope="col">Opens</th><th scope="col">Keys</th><th scope="col">Opens</th></tr></thead><tbody><tr><td>g t</td><td>To do</td><td>g v</td><td>Vehicles</td></tr><tr><td>g r</td><td>Requests</td><td>g l</td><td>Listings</td></tr><tr><td>g b</td><td>Bookings</td><td>g a</td><td>Applications</td></tr><tr><td>g c</td><td>Calendar</td><td>g o</td><td>Owners</td></tr><tr><td>g k</td><td>Tasks</td><td>g m</td><td>Payments and refunds</td></tr><tr><td>g s</td><td>All settings</td><td>/</td><td>Search</td></tr></tbody></table></div></section>');
select app.guide_release_section('admin', 'requests-offers-and-bookings', 'chapter', 'people-and-access', 'Every booking starts as a request. You check it, adjust it and send the offer. After that, the booking page holds the money, documents, changes and history.

## The request queue

Open **Bookings** > **Requests**. The oldest waiting request is at the top.

1. Filter by New, Waiting on the renter, Pushed back, Offer out, Signing and payment, or Offer expired.
2. Waiting shows how long the renter has waited; red means past the first reply target (5 minutes, set in Program settings). Open a booking number to answer it.

![](/guides/img/admin-02-requests-desktop-6521282d.jpg "desktop; size: 1440 820; address: carmacars.ca/admin/requests; pins: 1 18.5 21.2, 2 25.3 31.7")

> Good to know: A request whose pickup time passes without an offer expires by itself, with a note in its history. The renter is not emailed unless "Email the renter when their request expires that way" is on in Program settings.

## Answer a request with an offer

1. The Review and offer tab shows the request as the renter sent it.
2. Adjust the car, the dates, the rate type, the places, the rates and fees, the deposit and extras.
3. Price on the right updates as you change things.
4. Add a message, choose how long the offer stays open, then press **Send the offer**.

![](/guides/img/admin-03-booking-review-desktop-84570463.jpg "desktop; size: 1440 1060; address: carmacars.ca/admin/bookings/CC-10056?tab=review; pins: 1 21.7 16.4, 2 20.0 45.4, 3 65.0 45.4, 4 96.5 98.8")

5. Changed fields but not ready to send? Press **Save changes**. The panel "The offer as the renter sees it" shows the result.
6. Can''t do it? Press **Decline** and fill in Reason and any alternative.
7. Need an answer first? Press **Ask the renter** to send a question.

![](/guides/img/admin-03-booking-review-desktop-1139f8f9.jpg "desktop; size: 620 810; address: carmacars.ca/admin/bookings/CC-10056?tab=review; pins: 5 91.9 33.6")

> Tip: After the offer is out: **Withdraw to edit** takes it back, **Send again, later expiry** gives the renter more time, and **Renter approved by phone** records a yes given on a call.

## A booking

Open **Bookings** > **Bookings**, then a booking number. Or type the number in the search box.

1. Tabs: Overview, Money, Changes, History, and Drivers and documents.
2. Overview shows the trip, the renter, what is still missing for the handover, and the price.
3. Open tasks for this booking, with the queue and the due time.
4. Top right: **Stop blocking the calendar**, **Cancel for the renter** and **Cancel by CarmaCars**.

![](/guides/img/admin-04-booking-desktop-b56b668a.jpg "desktop; size: 1440 960; address: carmacars.ca/admin/bookings/CC-10057; pins: 1 20.1 24.0, 2 34.7 58.3, 3 20.1 72.9, 4 90.3 18.3")

## Propose a change to a confirmed booking

The renter gets an email and answers on their booking. The calendar moves only when they accept.

1. Open the booking''s Changes tab. Under Propose a change, set the new pickup, return or car.
2. To price it by hand, type a New rental charge before tax. Leave it empty to use the car''s rates.
3. Write the Reason, for the renter. They read it.
4. Press **Preview the price**, then **Send to the renter**.

![](/guides/img/admin-05-booking-changes-desktop-0b06af9a.jpg "desktop; size: 1230 530; address: carmacars.ca/admin/bookings/CC-10057?tab=changes; pins: 1 12.9 15.3, 2 35.0 30.6, 3 49.8 59.1, 4 30.9 73.2")

## Who a booking is credited to

Overview (and Review and offer) shows the Sales credit: the staff member the booking counts for in their sales.

1. A quote or a rental is credited to whoever created or added it. A request from the website is credited to whoever sent its first offer.
2. To give it to someone else, press **Reassign**, choose who (or Nobody), say whether they sourced the client and write the reason. The booking''s history and the audit log keep it, and the deal stays in the same week and month.
3. Sourced means the staff member chose I sourced this client when they entered it, it came with a field staff referral link, or you credited it. Only a sourced booking earns a staff commission. A website request earns none unless you credit someone.
4. Someone said they sourced a website request? The credit line shows the claim: press **Credit them** or **Not theirs**, with a reason.
5. A price typed by hand shows beside the rate-sheet price, with the reason. A price under the floor or past the discount limit is flagged: press **Mark reviewed** once you have looked at it.

> Tip: The renter has 48 hours to accept (and sign the amendment) or decline, with one reminder. Any extra is charged to their Card on File; a lower price raises a refund for your approval.
', 'Requests, offers and bookings', 'Answer a request with an offer, run a booking, and propose a change.',
  'Every booking starts as a request. You check it, adjust it and send the offer. After that, the booking page holds the money, documents, changes and history.

## The request queue

Open **Bookings** > **Requests**. The oldest waiting request is at the top.

1. Filter by New, Waiting on the renter, Pushed back, Offer out, Signing and payment, or Offer expired.
2. Waiting shows how long the renter has waited; red means past the first reply target (5 minutes, set in Program settings). Open a booking number to answer it.

![](/guides/img/admin-02-requests-desktop-6521282d.jpg "desktop; size: 1440 820; address: carmacars.ca/admin/requests; pins: 1 18.5 21.2, 2 25.3 31.7")

> Good to know: A request whose pickup time passes without an offer expires by itself, with a note in its history. The renter is not emailed unless "Email the renter when their request expires that way" is on in Program settings.

## Answer a request with an offer

1. The Review and offer tab shows the request as the renter sent it.
2. Adjust the car, the dates, the rate type, the places, the rates and fees, the deposit and extras.
3. Price on the right updates as you change things.
4. Add a message, choose how long the offer stays open, then press **Send the offer**.

![](/guides/img/admin-03-booking-review-desktop-84570463.jpg "desktop; size: 1440 1060; address: carmacars.ca/admin/bookings/CC-10056?tab=review; pins: 1 21.7 16.4, 2 20.0 45.4, 3 65.0 45.4, 4 96.5 98.8")

5. Changed fields but not ready to send? Press **Save changes**. The panel "The offer as the renter sees it" shows the result.
6. Can''t do it? Press **Decline** and fill in Reason and any alternative.
7. Need an answer first? Press **Ask the renter** to send a question.

![](/guides/img/admin-03-booking-review-desktop-1139f8f9.jpg "desktop; size: 620 810; address: carmacars.ca/admin/bookings/CC-10056?tab=review; pins: 5 91.9 33.6")

> Tip: After the offer is out: **Withdraw to edit** takes it back, **Send again, later expiry** gives the renter more time, and **Renter approved by phone** records a yes given on a call.

## A booking

Open **Bookings** > **Bookings**, then a booking number. Or type the number in the search box.

1. Tabs: Overview, Money, Changes, History, and Drivers and documents.
2. Overview shows the trip, the renter, what is still missing for the handover, and the price.
3. Open tasks for this booking, with the queue and the due time.
4. Top right: **Stop blocking the calendar**, **Cancel for the renter** and **Cancel by CarmaCars**.

![](/guides/img/admin-04-booking-desktop-b56b668a.jpg "desktop; size: 1440 960; address: carmacars.ca/admin/bookings/CC-10057; pins: 1 20.1 24.0, 2 34.7 58.3, 3 20.1 72.9, 4 90.3 18.3")

## Renter documents: licence and proof of coverage

A renter''s licence photos, selfie and proof of coverage (OPCF 27 or a credit card''s rental coverage) are checked before the handover. You check them yourself; no task is needed.

1. A booking with documents waiting is a line on To do: "Check ''s documents for booking ", marked Now when the pickup is within two days. Press **Review documents**.
2. The pop-up shows each driver''s images and the coverage: the insurer, policy number and expiry, or the card, its type and whether the name matches.
3. Tick the checks, then **Approve**. Or type the reason the renter reads and press **Reject**: they are asked for a new one.
4. The same pop-up is on the booking: the card Renter documents (**Review documents**) on Overview and on Drivers and documents.

> Tip: Each opening of a renter''s documents is logged. The links to the images last one minute.

## Propose a change to a confirmed booking

The renter gets an email and answers on their booking. The calendar moves only when they accept.

1. Open the booking''s Changes tab. Under Propose a change, set the new pickup, return or car.
2. To price it by hand, type a New rental charge before tax. Leave it empty to use the car''s rates.
3. Write the Reason, for the renter. They read it.
4. Press **Preview the price**, then **Send to the renter**.

![](/guides/img/admin-05-booking-changes-desktop-0b06af9a.jpg "desktop; size: 1230 530; address: carmacars.ca/admin/bookings/CC-10057?tab=changes; pins: 1 12.9 15.3, 2 35.0 30.6, 3 49.8 59.1, 4 30.9 73.2")

## Who a booking is credited to

Overview (and Review and offer) shows the Sales credit: the staff member the booking counts for in their sales.

1. A quote or a rental is credited to whoever created or added it. A request from the website is credited to whoever sent its first offer.
2. To give it to someone else, press **Reassign**, choose who (or Nobody), say whether they sourced the client and write the reason. The booking''s history and the audit log keep it, and the deal stays in the same week and month.
3. Sourced means the staff member chose I sourced this client when they entered it, it came with a field staff referral link, or you credited it. Only a sourced booking earns a staff commission. A website request earns none unless you credit someone.
4. Someone said they sourced a website request? The credit line shows the claim: press **Credit them** or **Not theirs**, with a reason.
5. A price typed by hand shows beside the rate-sheet price, with the reason. A price under the floor or past the discount limit is flagged: press **Mark reviewed** once you have looked at it.

> Tip: The renter has 48 hours to accept (and sign the amendment) or decline, with one reminder. Any extra is charged to their Card on File; a lower price raises a refund for your approval.
',
  '<p class="gd-p">Every booking starts as a request. You check it, adjust it and send the offer. After that, the booking page holds the money, documents, changes and history.</p><section class="gd-task" id="requests-offers-and-bookings-the-request-queue" data-gd-task><h2 class="gd-h2">The request queue</h2><p class="gd-p">Open <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Requests</b>. The oldest waiting request is at the top.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Filter by New, Waiting on the renter, Pushed back, Offer out, Signing and payment, or Offer expired.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Waiting shows how long the renter has waited; red means past the first reply target (5 minutes, set in Program settings). Open a booking number to answer it.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/requests</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/820"><img src="/guides/img/admin-02-requests-desktop-6521282d.jpg" alt="" loading="lazy" decoding="async" width="1440" height="820"><span class="gd-pin" style="left:18.5%;top:21.2%" aria-hidden="true">1</span><span class="gd-pin" style="left:25.3%;top:31.7%" aria-hidden="true">2</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A request whose pickup time passes without an offer expires by itself, with a note in its history. The renter is not emailed unless &quot;Email the renter when their request expires that way&quot; is on in Program settings.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-answer-a-request-with-an-offer" data-gd-task><h2 class="gd-h2">Answer a request with an offer</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The Review and offer tab shows the request as the renter sent it.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Adjust the car, the dates, the rate type, the places, the rates and fees, the deposit and extras.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Price on the right updates as you change things.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Add a message, choose how long the offer stays open, then press <b class="gd-ui">Send the offer</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10056?tab=review</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1060"><img src="/guides/img/admin-03-booking-review-desktop-84570463.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1060"><span class="gd-pin" style="left:21.7%;top:16.4%" aria-hidden="true">1</span><span class="gd-pin" style="left:20%;top:45.4%" aria-hidden="true">2</span><span class="gd-pin" style="left:65%;top:45.4%" aria-hidden="true">3</span><span class="gd-pin" style="left:96.5%;top:98.8%" aria-hidden="true">4</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="5"><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Changed fields but not ready to send? Press <b class="gd-ui">Save changes</b>. The panel &quot;The offer as the renter sees it&quot; shows the result.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Can&#39;t do it? Press <b class="gd-ui">Decline</b> and fill in Reason and any alternative.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Need an answer first? Press <b class="gd-ui">Ask the renter</b> to send a question.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10056?tab=review</span></div><div class="gd-imgwrap" style="aspect-ratio:620/810"><img src="/guides/img/admin-03-booking-review-desktop-1139f8f9.jpg" alt="" loading="lazy" decoding="async" width="620" height="810"><span class="gd-pin" style="left:91.9%;top:33.6%" aria-hidden="true">5</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>After the offer is out: <b class="gd-ui">Withdraw to edit</b> takes it back, <b class="gd-ui">Send again, later expiry</b> gives the renter more time, and <b class="gd-ui">Renter approved by phone</b> records a yes given on a call.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-a-booking" data-gd-task><h2 class="gd-h2">A booking</h2><p class="gd-p">Open <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Bookings</b>, then a booking number. Or type the number in the search box.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Tabs: Overview, Money, Changes, History, and Drivers and documents.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Overview shows the trip, the renter, what is still missing for the handover, and the price.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Open tasks for this booking, with the queue and the due time.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Top right: <b class="gd-ui">Stop blocking the calendar</b>, <b class="gd-ui">Cancel for the renter</b> and <b class="gd-ui">Cancel by CarmaCars</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10057</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/960"><img src="/guides/img/admin-04-booking-desktop-b56b668a.jpg" alt="" loading="lazy" decoding="async" width="1440" height="960"><span class="gd-pin" style="left:20.1%;top:24%" aria-hidden="true">1</span><span class="gd-pin" style="left:34.7%;top:58.3%" aria-hidden="true">2</span><span class="gd-pin" style="left:20.1%;top:72.9%" aria-hidden="true">3</span><span class="gd-pin" style="left:90.3%;top:18.3%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="requests-offers-and-bookings-renter-documents-licence-and-proof-of-coverage" data-gd-task><h2 class="gd-h2">Renter documents: licence and proof of coverage</h2><p class="gd-p">A renter&#39;s licence photos, selfie and proof of coverage (OPCF 27 or a credit card&#39;s rental coverage) are checked before the handover. You check them yourself; no task is needed.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A booking with documents waiting is a line on To do: &quot;Check &#39;s documents for booking &quot;, marked Now when the pickup is within two days. Press <b class="gd-ui">Review documents</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The pop-up shows each driver&#39;s images and the coverage: the insurer, policy number and expiry, or the card, its type and whether the name matches.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Tick the checks, then <b class="gd-ui">Approve</b>. Or type the reason the renter reads and press <b class="gd-ui">Reject</b>: they are asked for a new one.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The same pop-up is on the booking: the card Renter documents (<b class="gd-ui">Review documents</b>) on Overview and on Drivers and documents.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Each opening of a renter&#39;s documents is logged. The links to the images last one minute.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-propose-a-change-to-a-confirmed-booking" data-gd-task><h2 class="gd-h2">Propose a change to a confirmed booking</h2><p class="gd-p">The renter gets an email and answers on their booking. The calendar moves only when they accept.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the booking&#39;s Changes tab. Under Propose a change, set the new pickup, return or car.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">To price it by hand, type a New rental charge before tax. Leave it empty to use the car&#39;s rates.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Write the Reason, for the renter. They read it.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Preview the price</b>, then <b class="gd-ui">Send to the renter</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10057?tab=changes</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/530"><img src="/guides/img/admin-05-booking-changes-desktop-0b06af9a.jpg" alt="" loading="lazy" decoding="async" width="1230" height="530"><span class="gd-pin" style="left:12.9%;top:15.3%" aria-hidden="true">1</span><span class="gd-pin" style="left:35%;top:30.6%" aria-hidden="true">2</span><span class="gd-pin" style="left:49.8%;top:59.1%" aria-hidden="true">3</span><span class="gd-pin" style="left:30.9%;top:73.2%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="requests-offers-and-bookings-who-a-booking-is-credited-to" data-gd-task><h2 class="gd-h2">Who a booking is credited to</h2><p class="gd-p">Overview (and Review and offer) shows the Sales credit: the staff member the booking counts for in their sales.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A quote or a rental is credited to whoever created or added it. A request from the website is credited to whoever sent its first offer.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">To give it to someone else, press <b class="gd-ui">Reassign</b>, choose who (or Nobody), say whether they sourced the client and write the reason. The booking&#39;s history and the audit log keep it, and the deal stays in the same week and month.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Sourced means the staff member chose I sourced this client when they entered it, it came with a field staff referral link, or you credited it. Only a sourced booking earns a staff commission. A website request earns none unless you credit someone.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Someone said they sourced a website request? The credit line shows the claim: press <b class="gd-ui">Credit them</b> or <b class="gd-ui">Not theirs</b>, with a reason.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A price typed by hand shows beside the rate-sheet price, with the reason. A price under the floor or past the discount limit is flagged: press <b class="gd-ui">Mark reviewed</b> once you have looked at it.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The renter has 48 hours to accept (and sign the amendment) or decline, with one reminder. Any extra is charged to their Card on File; a lower price raises a refund for your approval.</div></aside></section>');
select app.guide_release_section('admin', 'calendar-sync-with-turo-and-other-platforms', 'chapter', 'calendars', 'A car rented on Turo, Getaround or another site must never be booked twice. Turo has no calendar link, so Turo works by email: Turo''s trip emails block the car here, and you block our bookings on Turo by hand. Getaround, Google Calendar and other sites work through calendar links (iCal), both ways.

## Set up Turo by email (once)

Turo emails rent@carmacars.ca for every trip booked, changed, extended or cancelled. One Gmail filter forwards those emails to trips@in.carmacars.ca, and each one blocks the car here within a minute.

1. In Gmail (rent@carmacars.ca): Settings, See all settings, Forwarding and POP/IMAP. Press Add a forwarding address and type trips@in.carmacars.ca.
2. Gmail sends a confirmation code to that address. Open **Cars** > **Calendar sync**: the code shows under "Turo by email" (and To do shows "Gmail forwarding to confirm"). Type it in Gmail and press Verify. Leave forwarding itself off: only the filter forwards.
3. In Gmail, in the search box, show the search options. From: turo.com. Press Create filter, tick Forward it to: trips@in.carmacars.ca, and press Create filter.
4. On Calendar sync, for each car on Turo, press **This car is on Turo**, type its name exactly as Turo''s emails show it (for example Mercedes-Benz GLC 2021) and press **Save**. The Turo car number (the number at the end of its Turo page address) is optional; the plate and VIN are matched too.

## Turo trips on the calendar

1. A trip booked on Turo becomes an "External booking" block on the car, with the turnaround before and after it. The car cannot be requested, offered or booked here for those times.
2. A changed or extended trip moves its block; a cancelled trip frees the car. An older email never undoes a newer one.
3. Each car lists its Turo trips: the dates, the Turo trip number and the guest''s first name. Press Cancelled if Turo cancelled a trip and its email did not come.
4. **Add a Turo trip**: the trip start and end (Toronto time), and the Turo trip number if you have it. Use it for a trip whose email did not come.
5. Only what the email says is kept: the car, the dates, the trip number and the guest''s first name. The email itself is never stored.

## Turo emails to check

When the reader is not sure (which car, the dates or the trip number), the email waits under "Turo emails to check", with a Fleet task and a line on To do.

1. Read what was found and the short excerpt (no email addresses, phone numbers or links). Check the trip on Turo.
2. Press **Add as a Turo trip**, choose the car, check the dates and press **Add this trip**. The email is checked and the task closes.
3. Not a trip (a request, a message)? Press **Dismiss**.

## Block our bookings on Turo (Done on Turo)

Turo cannot read our calendar. Each car on Turo lists, under "Block on Turo", the CarmaCars bookings not yet blocked there.

1. Open the car''s calendar on Turo and block the dates shown (the turnaround is included).
2. Press **Done on Turo**. The booking leaves the list.
3. If the booking''s dates change, it comes back with the old dates to free first. A booking cancelled here shows the dates to free on Turo: free them, then press Freed on Turo.

## Getaround, Google Calendar and other calendar links

**Cars** > **Calendar sync**, for a platform that gives a calendar (iCal) link.

1. Copy the car''s calendar link on the platform (look for "Export calendar" or "iCal"). On Calendar sync, open **Add a calendar link**, choose Getaround, Google Calendar or Other, paste the link and press **Add the link**.
2. The link is read at once and then every 10 minutes; **Sync now** reads it at once. Each trip becomes an "External booking" block with the turnaround.
3. Send our bookings there: press **Copy** next to "For Getaround" (or "For Google Calendar", or "For any other platform") under "This car''s CarmaCars calendar" and paste it into the platform''s calendar import. It shows only "Booked" times: no names, numbers or prices.
4. If a link was shared by mistake, press **Make a new link**. The old one stops working at once: paste the new one into every platform again.

## Double bookings

If a trip on Turo or another platform overlaps a confirmed CarmaCars booking of the same car, we tell you at once.

- An urgent Fleet task "Double booking: on Turo and CC-1042", a line on To do and an email to Fleet and the Admins.
- Calendar sync lists it at the top with both trips. Move, swap or cancel one of the two. The task closes by itself once they no longer overlap.
- An offer or a booking awaiting payment over a trip on another platform raises a task for customer service: its payment would be refused, so withdraw the offer or change the dates.

## A link that stops working

A platform answers an error when a link is reset or removed. After 3 failed reads in a row (a Program setting) Fleet gets a task and an email, and To do shows "Calendar links not working". The trips already read stay on the calendar. Copy the link from the platform again, remove the old one and add the new one.

> Good to know: A block from another platform can be removed from the calendar like any block; calendar sync will not put it back. In Program settings, "Calendar sync" and "Turo by email": on or off, how often links are read, the inbound address, the mailboxes allowed to forward (rent@carmacars.ca) and how long the email log is kept (90 days).
', 'Calendar sync with Turo and other platforms', 'Turo by email (set up once, cars found by themselves, "Which car is this?", the guest, Done on Turo), calendar links for other platforms, clashes.',
  'A car rented on Turo, Getaround or another site must never be booked twice. Turo has no calendar link, so Turo works by email: Turo''s trip emails block the car here, and you block our bookings on Turo by hand. Getaround, Google Calendar and other sites work through calendar links (iCal), both ways.

## Set up Turo by email (once)

Turo emails rent@carmacars.ca for every trip booked, changed, extended or cancelled. One Gmail filter forwards those emails to trips@in.carmacars.ca, and each one blocks the car here within a minute.

1. In Gmail (rent@carmacars.ca): Settings, See all settings, Forwarding and POP/IMAP. Press Add a forwarding address and type trips@in.carmacars.ca.
2. Gmail sends a confirmation code to that address. Open **Cars** > **Calendar sync**: the code shows under "Turo by email" (and To do shows "Gmail forwarding to confirm"). Type it in Gmail and press Verify. Leave forwarding itself off: only the filter forwards.
3. In Gmail, in the search box, show the search options. From: turo.com. Press Create filter, tick Forward it to: trips@in.carmacars.ca, and press Create filter.
4. Nothing to set up per car. Every active car (not the sample cars) is matched by itself: see the next task.

## How Turo emails find their car (automatic)

Each Turo email is matched to one of our cars by itself. You never type a car''s name on Turo.

- The reader looks at the Turo car number in the email''s links and pictures, the VIN, the plate, the year, make and model (C-Class finds a C 300, Model3 a Model 3, 3 Series a 330i), trim and colour words, the trip already on a car, and whether a car is already busy at those dates.
- A clear winner is applied at once. When two cars are close (two black 2021 Jettas), the assistant picks between them only if the email tells them apart; otherwise the email waits as "Which car is this?".
- Every match teaches the car what Turo calls it (its Turo car number and the name in Turo''s emails), so the next email for that car matches at once. Each car on Calendar sync shows what it learned; press Forget next to one that is wrong.
- Rarely needed: **Type its name on Turo (optional)** on a car whose Turo name the reader cannot place. The Turo car number there is optional too.

## Turo trips on the calendar

1. A trip booked on Turo becomes an "External booking" block on the car, with the turnaround before and after it. The car cannot be requested, offered or booked here for those times.
2. A changed or extended trip moves its block; a cancelled trip frees the car. An older email never undoes a newer one.
3. Each car lists its Turo trips: the dates, the Turo trip number, the guest''s name as Turo shows it and their phone when the email includes it (press Call). The car''s calendar block shows them too. Press Cancelled if Turo cancelled a trip and its email did not come.
4. **Add a Turo trip**: the trip start and end (Toronto time), and the Turo trip number if you have it. Use it for a trip whose email did not come.
5. Only what the email says is kept: the car, the dates, the trip number, and the guest''s name, phone and email when Turo shows them (a hidden or masked number is never taken). The email itself is never stored.
6. Each guest gets one contact record (source Turo), so a Turo guest who calls our line or writes in Live chat is recognised by their phone. Contact them only about their trip: never add them to a marketing list or send promotions (Canada''s anti-spam law and Turo''s rules on taking guests off the platform). Nothing is sent to them by itself.

## Which car is this? (Turo emails to check)

Only an email the reader cannot be sure about waits under "Turo emails to check", with a Fleet task and a line on To do.

1. To do shows "Turo emails: which car is this?". Press **Choose the car**, or **Which car is this?** on the email in Calendar sync.
2. The pop-up shows what Turo calls the car and the trip, then our best guesses first (with colour and the plate''s last 3). Press the right car. Not among them? Choose it under Another car and press This car.
3. The trip is added and blocks the car, the task closes, and the car remembers what Turo called it: the next email for it matches by itself. Other emails waiting with the same Turo car number are matched at once.
4. Something else is missing (the dates or the trip number)? Check the trip on Turo, press **Add as a Turo trip**, choose the car, check the dates and press **Add this trip**. Not a trip (a request, a message)? Press **Dismiss**.

## Block our bookings on Turo (Done on Turo)

Turo cannot read our calendar. Each car on Turo lists, under "Block on Turo", the CarmaCars bookings not yet blocked there.

1. Open the car''s calendar on Turo and block the dates shown (the turnaround is included).
2. Press **Done on Turo**. The booking leaves the list.
3. If the booking''s dates change, it comes back with the old dates to free first. A booking cancelled here shows the dates to free on Turo: free them, then press Freed on Turo.

## Getaround, Google Calendar and other calendar links

**Cars** > **Calendar sync**, for a platform that gives a calendar (iCal) link.

1. Copy the car''s calendar link on the platform (look for "Export calendar" or "iCal"). On Calendar sync, open **Add a calendar link**, choose Getaround, Google Calendar or Other, paste the link and press **Add the link**.
2. The link is read at once and then every 10 minutes; **Sync now** reads it at once. Each trip becomes an "External booking" block with the turnaround.
3. Send our bookings there: press **Copy** next to "For Getaround" (or "For Google Calendar", or "For any other platform") under "This car''s CarmaCars calendar" and paste it into the platform''s calendar import. It shows only "Booked" times: no names, numbers or prices.
4. If a link was shared by mistake, press **Make a new link**. The old one stops working at once: paste the new one into every platform again.

## Double bookings

If a trip on Turo or another platform overlaps a confirmed CarmaCars booking of the same car, we tell you at once.

- An urgent Fleet task "Double booking: on Turo and CC-1042", a line on To do and an email to Fleet and the Admins.
- Calendar sync lists it at the top with both trips. Move, swap or cancel one of the two. The task closes by itself once they no longer overlap.
- An offer or a booking awaiting payment over a trip on another platform raises a task for customer service: its payment would be refused, so withdraw the offer or change the dates.

## A link that stops working

A platform answers an error when a link is reset or removed. After 3 failed reads in a row (a Program setting) Fleet gets a task and an email, and To do shows "Calendar links not working". The trips already read stay on the calendar. Copy the link from the platform again, remove the old one and add the new one.

> Good to know: A block from another platform can be removed from the calendar like any block; calendar sync will not put it back. In Program settings, "Calendar sync" and "Turo by email": on or off, how often links are read, the inbound address, the mailboxes allowed to forward (rent@carmacars.ca) and how long the email log is kept (90 days).
',
  '<p class="gd-p">A car rented on Turo, Getaround or another site must never be booked twice. Turo has no calendar link, so Turo works by email: Turo&#39;s trip emails block the car here, and you block our bookings on Turo by hand. Getaround, Google Calendar and other sites work through calendar links (iCal), both ways.</p><section class="gd-task" id="calendar-sync-with-turo-and-other-platforms-set-up-turo-by-email-once" data-gd-task><h2 class="gd-h2">Set up Turo by email (once)</h2><p class="gd-p">Turo emails rent@carmacars.ca for every trip booked, changed, extended or cancelled. One Gmail filter forwards those emails to trips@in.carmacars.ca, and each one blocks the car here within a minute.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">In Gmail (rent@carmacars.ca): Settings, See all settings, Forwarding and POP/IMAP. Press Add a forwarding address and type trips@in.carmacars.ca.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Gmail sends a confirmation code to that address. Open <b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Calendar sync</b>: the code shows under &quot;Turo by email&quot; (and To do shows &quot;Gmail forwarding to confirm&quot;). Type it in Gmail and press Verify. Leave forwarding itself off: only the filter forwards.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">In Gmail, in the search box, show the search options. From: turo.com. Press Create filter, tick Forward it to: trips@in.carmacars.ca, and press Create filter.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Nothing to set up per car. Every active car (not the sample cars) is matched by itself: see the next task.</div></li></ol></div></section><section class="gd-task" id="calendar-sync-with-turo-and-other-platforms-how-turo-emails-find-their-car-automatic" data-gd-task><h2 class="gd-h2">How Turo emails find their car (automatic)</h2><p class="gd-p">Each Turo email is matched to one of our cars by itself. You never type a car&#39;s name on Turo.</p><ul class="gd-ul"><li>The reader looks at the Turo car number in the email&#39;s links and pictures, the VIN, the plate, the year, make and model (C-Class finds a C 300, Model3 a Model 3, 3 Series a 330i), trim and colour words, the trip already on a car, and whether a car is already busy at those dates.</li><li>A clear winner is applied at once. When two cars are close (two black 2021 Jettas), the assistant picks between them only if the email tells them apart; otherwise the email waits as &quot;Which car is this?&quot;.</li><li>Every match teaches the car what Turo calls it (its Turo car number and the name in Turo&#39;s emails), so the next email for that car matches at once. Each car on Calendar sync shows what it learned; press Forget next to one that is wrong.</li><li>Rarely needed: <b class="gd-ui">Type its name on Turo (optional)</b> on a car whose Turo name the reader cannot place. The Turo car number there is optional too.</li></ul></section><section class="gd-task" id="calendar-sync-with-turo-and-other-platforms-turo-trips-on-the-calendar" data-gd-task><h2 class="gd-h2">Turo trips on the calendar</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A trip booked on Turo becomes an &quot;External booking&quot; block on the car, with the turnaround before and after it. The car cannot be requested, offered or booked here for those times.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">A changed or extended trip moves its block; a cancelled trip frees the car. An older email never undoes a newer one.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Each car lists its Turo trips: the dates, the Turo trip number, the guest&#39;s name as Turo shows it and their phone when the email includes it (press Call). The car&#39;s calendar block shows them too. Press Cancelled if Turo cancelled a trip and its email did not come.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Add a Turo trip</b>: the trip start and end (Toronto time), and the Turo trip number if you have it. Use it for a trip whose email did not come.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Only what the email says is kept: the car, the dates, the trip number, and the guest&#39;s name, phone and email when Turo shows them (a hidden or masked number is never taken). The email itself is never stored.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Each guest gets one contact record (source Turo), so a Turo guest who calls our line or writes in Live chat is recognised by their phone. Contact them only about their trip: never add them to a marketing list or send promotions (Canada&#39;s anti-spam law and Turo&#39;s rules on taking guests off the platform). Nothing is sent to them by itself.</div></li></ol></div></section><section class="gd-task" id="calendar-sync-with-turo-and-other-platforms-which-car-is-this-turo-emails-to-check" data-gd-task><h2 class="gd-h2">Which car is this? (Turo emails to check)</h2><p class="gd-p">Only an email the reader cannot be sure about waits under &quot;Turo emails to check&quot;, with a Fleet task and a line on To do.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">To do shows &quot;Turo emails: which car is this?&quot;. Press <b class="gd-ui">Choose the car</b>, or <b class="gd-ui">Which car is this?</b> on the email in Calendar sync.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The pop-up shows what Turo calls the car and the trip, then our best guesses first (with colour and the plate&#39;s last 3). Press the right car. Not among them? Choose it under Another car and press This car.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The trip is added and blocks the car, the task closes, and the car remembers what Turo called it: the next email for it matches by itself. Other emails waiting with the same Turo car number are matched at once.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Something else is missing (the dates or the trip number)? Check the trip on Turo, press <b class="gd-ui">Add as a Turo trip</b>, choose the car, check the dates and press <b class="gd-ui">Add this trip</b>. Not a trip (a request, a message)? Press <b class="gd-ui">Dismiss</b>.</div></li></ol></div></section><section class="gd-task" id="calendar-sync-with-turo-and-other-platforms-block-our-bookings-on-turo-done-on-turo" data-gd-task><h2 class="gd-h2">Block our bookings on Turo (Done on Turo)</h2><p class="gd-p">Turo cannot read our calendar. Each car on Turo lists, under &quot;Block on Turo&quot;, the CarmaCars bookings not yet blocked there.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the car&#39;s calendar on Turo and block the dates shown (the turnaround is included).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Done on Turo</b>. The booking leaves the list.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">If the booking&#39;s dates change, it comes back with the old dates to free first. A booking cancelled here shows the dates to free on Turo: free them, then press Freed on Turo.</div></li></ol></div></section><section class="gd-task" id="calendar-sync-with-turo-and-other-platforms-getaround-google-calendar-and-other-calendar-links" data-gd-task><h2 class="gd-h2">Getaround, Google Calendar and other calendar links</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Calendar sync</b>, for a platform that gives a calendar (iCal) link.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Copy the car&#39;s calendar link on the platform (look for &quot;Export calendar&quot; or &quot;iCal&quot;). On Calendar sync, open <b class="gd-ui">Add a calendar link</b>, choose Getaround, Google Calendar or Other, paste the link and press <b class="gd-ui">Add the link</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The link is read at once and then every 10 minutes; <b class="gd-ui">Sync now</b> reads it at once. Each trip becomes an &quot;External booking&quot; block with the turnaround.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Send our bookings there: press <b class="gd-ui">Copy</b> next to &quot;For Getaround&quot; (or &quot;For Google Calendar&quot;, or &quot;For any other platform&quot;) under &quot;This car&#39;s CarmaCars calendar&quot; and paste it into the platform&#39;s calendar import. It shows only &quot;Booked&quot; times: no names, numbers or prices.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">If a link was shared by mistake, press <b class="gd-ui">Make a new link</b>. The old one stops working at once: paste the new one into every platform again.</div></li></ol></div></section><section class="gd-task" id="calendar-sync-with-turo-and-other-platforms-double-bookings" data-gd-task><h2 class="gd-h2">Double bookings</h2><p class="gd-p">If a trip on Turo or another platform overlaps a confirmed CarmaCars booking of the same car, we tell you at once.</p><ul class="gd-ul"><li>An urgent Fleet task &quot;Double booking: on Turo and CC-1042&quot;, a line on To do and an email to Fleet and the Admins.</li><li>Calendar sync lists it at the top with both trips. Move, swap or cancel one of the two. The task closes by itself once they no longer overlap.</li><li>An offer or a booking awaiting payment over a trip on another platform raises a task for customer service: its payment would be refused, so withdraw the offer or change the dates.</li></ul></section><section class="gd-task" id="calendar-sync-with-turo-and-other-platforms-a-link-that-stops-working" data-gd-task><h2 class="gd-h2">A link that stops working</h2><p class="gd-p">A platform answers an error when a link is reset or removed. After 3 failed reads in a row (a Program setting) Fleet gets a task and an email, and To do shows &quot;Calendar links not working&quot;. The trips already read stay on the calendar. Copy the link from the platform again, remove the old one and add the new one.</p><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A block from another platform can be removed from the calendar like any block; calendar sync will not put it back. In Program settings, &quot;Calendar sync&quot; and &quot;Turo by email&quot;: on or off, how often links are read, the inbound address, the mailboxes allowed to forward (rent@carmacars.ca) and how long the email log is kept (90 days).</div></aside></section>');
select app.guide_release_section('admin', 'fleet-and-listings', 'chapter', 'calendar-sync-with-turo-and-other-platforms', 'Vehicles is the fleet. Listings is the pipeline that turns a car into a page on carmacars.ca: photos, copy, a duplicate check and a covered plate on every public photo.

## Vehicles

**Cars** > **Vehicles**

1. Filter by status and mode. Each row shows the plate, class, owner, mode, status, listing and daily rate.
2. Search by plate, model or owner. **Cars** > **Rates for many cars** changes the rates of many cars at once.
3. Open a car for its tabs: Overview, Rates, Fees and coverage, Calendar, Listing, and Owner, documents, tracker.

![](/guides/img/admin-08-vehicles-desktop-46461f49.jpg "desktop; size: 1440 900; address: carmacars.ca/admin/vehicles; pins: 1 18.5 19.3, 2 83.5 12.9, 3 73.6 38.9")

## Set a car''s rates and kilometres

Open the car, then the **Rates** tab. Everything on it saves together, in one step.

1. Type the four rates. Only the daily rate is needed: an empty weekend rate is the daily rate, an empty weekly rate is 6 days at the daily rate, and an empty monthly rate is 22 days.
2. Kilometres: keep **Use the defaults** (the kilometres a day in Settings, Kilometre choices, and the extra kilometre rate in Fee defaults for the car''s class), or choose **Custom for this car** and type them.
3. Check the deposit (the class default is filled in), and the delivery and pickup fees (0: not offered).
4. Read What renters pay under the fields: real prices for a weekend, a few weekdays, a week and a month, worked out the way bookings are priced. Press **Save the rates**.

| Rate | What it means |
| --- | --- |
| Daily rate | A price per day, for each day that starts on a Sunday, Monday, Tuesday, Wednesday or Thursday |
| Weekend rate | A price per day, not for the whole weekend: each day that starts on a Friday or Saturday. Friday 10 am to Sunday 10 am is 2 days at this rate; Sunday to Monday is a daily day |
| Weekly rate | The price for 7 days. Rentals of 7 to 29 days cost this for each 7 days, counted by the day. A 1 to 6 day rental never costs more |
| Monthly rate | The price for 30 days. A 7 to 29 day rental never costs more |

> Tip: A problem shows on its own field, in words, as you type. When similar cars have rates, a line suggests them with Use these; it is only a hint. The same fields are on **Add a car**, so a car can be added with its rates in one pass.

> Coming soon: The Tracker card on a car says "Coming soon": live location, the remote immobilize request and mileage from the tracker need the tracker company''s connection first.

## The listing pipeline

Open **Cars** > **Listings**. A draft waiting for review shows Needs review.

1. Each row shows the car, plate, state, photos and the pipeline''s progress.
2. Press **Start a listing** to begin one for a car that has none.
3. Open a car to review it.

![](/guides/img/admin-09-listings-desktop-970819b6.jpg "desktop; size: 1440 560; address: carmacars.ca/admin/listings; pins: 1 53.5 37.0, 2 87.2 21.1, 3 32.6 37.0")

## Review a listing

1. Pipeline shows each step done, such as photo sizes, copy draft and backgrounds.
2. Similar cars on file lists possible duplicates. Press **Not a duplicate** or **Same car**. An open flag stops publishing.
3. The copy is written by itself from the car''s facts and published when it passes the checks: nothing to type. To change a line, press Change; that field is then locked and kept by every new version.
4. Under Photos, each public photo shows its plate state: Plate not checked, Plate covered or No plate visible.

![](/guides/img/admin-10-listing-review-desktop-352745fd.jpg "desktop; size: 1440 1100; address: carmacars.ca/admin/listings/7e43d38d-32bb-4666-a742-81813c3b7671; pins: 1 20.6 16.6, 2 86.1 47.5, 3 19.9 106.8, 4 74.9 106.8")

## Cover the licence plate

On each public photo press **Cover the plate**. The editor opens.

1. The editor suggests a box over the plate. Check it. **Suggest the plate** asks again.
2. Drag over a plate to draw a box. Drag a box to move it, or its corner to resize it.
3. Under Cover the plate with, choose **A CarmaCars plate**, **Pixelation** or **Blur**.
4. Press **Save the covered photo**. **Clear the boxes** starts over.
5. No plate in the shot? Press **No plate visible on this photo**.

![](/guides/img/admin-11-plate-editor-desktop-4219ad93.jpg "desktop; size: 690 703; address: carmacars.ca/admin/listings/7e43d38d-32bb-4666-a742-81813c3b7671; pins: 1 42.5 83.8, 2 49.6 29.9, 3 4.3 77.4, 4 15.5 83.8, 5 18.1 91.2")

> Tip: The covered photo replaces the public one; the original is kept privately. Keyboard: N adds a box, the arrows move it, Shift and the arrows resize it, Delete removes it.

## Publish

1. When every public photo is covered or marked, press **Approve and publish**.
2. Or press **Approve, publish later**, or **Send back** with what to fix.

> Watch out: Publishing waits for a plate decision on every public photo ("Cover the licence plate or mark it not visible on every public photo first"). Listings already live show "Plate not checked" until someone checks them.

## A listing without photos yet: sample photos

A car can be listed before its photos are taken. Until then the site shows a sample photo.

1. Submit the listing without photos. The listing copy is still written for you from the car''s details.
2. The car page and the car''s card show a sample photo, captioned "Sample photo", so renters know it is not this car. Staff see "Using sample photos" on the car and in Listings.
3. Publishing does not wait for a plate check: a sample photo has no plate.
4. Add the real photos when they are taken. Once real photos are approved they replace the sample at once; nothing else to do.

## Sample photos

**Settings** > **Sample photos**. The pictures a car shows until its real photos are in.

1. Every body type has a built-in picture (sedan, SUV, truck, van, coupe, hatchback, electric car).
2. Add your own: choose the Body type, and a Make and Model if the photo is of that exact model, pick the Photo, and press **Add the photo**.
3. The most specific photo wins: make and model, then make and body type, then body type. **Turn off** or **Delete** a photo you no longer want.
4. Cars using sample photos lists the cars still waiting for real photos. It is also a line on To do.

![](/guides/img/admin-36-sample-photos-desktop-55c64070.jpg "desktop; size: 1440 812; address: carmacars.ca/admin/settings/sample-photos; pins: 4 26.8 28.9")
', 'Fleet and listings', 'Vehicles, the listing pipeline, similar cars and covering licence plates.',
  'Vehicles is the fleet. Listings is the pipeline that turns a car into a page on carmacars.ca: photos, copy, a duplicate check and a covered plate on every public photo.

## Vehicles

**Cars** > **Vehicles**

1. Filter by status and mode. Each row shows the plate, class, owner, mode, status, listing and daily rate.
2. Search by plate, model or owner. **Cars** > **Rates for many cars** changes the rates of many cars at once.
3. Open a car for its tabs: Overview, Rates, Fees and coverage, Calendar, Listing, and Owner, documents, tracker.

![](/guides/img/admin-08-vehicles-desktop-46461f49.jpg "desktop; size: 1440 900; address: carmacars.ca/admin/vehicles; pins: 1 18.5 19.3, 2 83.5 12.9, 3 73.6 38.9")

## Set a car''s rates and kilometres

Open the car, then the **Rates** tab. Everything on it saves together, in one step.

1. Type the four rates. Only the daily rate is needed: an empty weekend rate is the daily rate, an empty weekly rate is 6 days at the daily rate, and an empty monthly rate is 22 days.
2. Kilometres: keep **Use the defaults** (the kilometres a day in Settings, Kilometre choices, and the extra kilometre rate in Fee defaults for the car''s class), or choose **Custom for this car** and type them.
3. Check the deposit (the class default is filled in), and the delivery and pickup fees: each is one way, an empty pickup fee is the delivery fee, and 0 means not offered.
4. Read What renters pay under the fields: real prices for a weekend, a few weekdays, a week and a month, worked out the way bookings are priced. Press **Save the rates**.

| Rate | What it means |
| --- | --- |
| Daily rate | A price per day, for each day that starts on a Sunday, Monday, Tuesday, Wednesday or Thursday |
| Weekend rate | A price per day, not for the whole weekend: each day that starts on a Friday or Saturday. Friday 10 am to Sunday 10 am is 2 days at this rate; Sunday to Monday is a daily day |
| Weekly rate | The price for 7 days. Rentals of 7 to 29 days cost this for each 7 days, counted by the day. A 1 to 6 day rental never costs more |
| Monthly rate | The price for 30 days. A 7 to 29 day rental never costs more |

> Tip: A problem shows on its own field, in words, as you type. When similar cars have rates, a line suggests them with Use these; it is only a hint. The same fields are on **Add a car**, so a car can be added with its rates in one pass.

> Coming soon: The Tracker card on a car says "Coming soon": live location, the remote immobilize request and mileage from the tracker need the tracker company''s connection first.

## The listing pipeline

Open **Cars** > **Listings**. A draft waiting for review shows Needs review.

1. Each row shows the car, plate, state, photos and the pipeline''s progress.
2. Press **Start a listing** to begin one for a car that has none.
3. Open a car to review it.

![](/guides/img/admin-09-listings-desktop-970819b6.jpg "desktop; size: 1440 560; address: carmacars.ca/admin/listings; pins: 1 53.5 37.0, 2 87.2 21.1, 3 32.6 37.0")

## Review a listing

1. Pipeline shows each step done, such as photo sizes, copy draft and backgrounds.
2. Similar cars on file lists possible duplicates. Press **Not a duplicate** or **Same car**. An open flag does not keep the car off the site; only Same car does.
3. The copy is written by itself from the car''s facts and published when it passes the checks: nothing to type. To change a line, press Change; that field is then locked and kept by every new version.
4. Under Photos, each public photo shows its plate state: Plate not checked, Plate covered or No plate visible.

![](/guides/img/admin-10-listing-review-desktop-352745fd.jpg "desktop; size: 1440 1100; address: carmacars.ca/admin/listings/7e43d38d-32bb-4666-a742-81813c3b7671; pins: 1 20.6 16.6, 2 86.1 47.5, 3 19.9 106.8, 4 74.9 106.8")

## Cover the licence plate

On each public photo press **Cover the plate**. The editor opens.

1. The editor suggests a box over the plate. Check it. **Suggest the plate** asks again.
2. Drag over a plate to draw a box. Drag a box to move it, or its corner to resize it.
3. Under Cover the plate with, choose **A CarmaCars plate**, **Pixelation** or **Blur**.
4. Press **Save the covered photo**. **Clear the boxes** starts over.
5. No plate in the shot? Press **No plate visible on this photo**.

![](/guides/img/admin-11-plate-editor-desktop-4219ad93.jpg "desktop; size: 690 703; address: carmacars.ca/admin/listings/7e43d38d-32bb-4666-a742-81813c3b7671; pins: 1 42.5 83.8, 2 49.6 29.9, 3 4.3 77.4, 4 15.5 83.8, 5 18.1 91.2")

> Tip: The covered photo replaces the public one; the original is kept privately. Keyboard: N adds a box, the arrows move it, Shift and the arrows resize it, Delete removes it.

## Publish

1. A real car that is not on the site is a line on To do: press **Set rates and publish**. The daily rate is filled in (the car''s own, or the suggested rate from similar cars or the class); change it if you like and press **Publish now**.
2. On the car itself, the Listing tab has **Publish now**; each open item of its checklist has a button to where it is done.
3. From a listing review: press **Approve and publish**, **Approve, publish later**, or **Send back** with what to fix.

> Watch out: The plate check never holds a car back: a real photo whose plate is not checked stays private (the other photos, or the sample photos, show instead) and goes public by itself once its plate is covered or marked not visible. Listings already live show "Plate not checked" on such photos.

## A listing without photos yet: sample photos

A car can be listed before its photos are taken. Until then the site shows a sample photo.

1. Submit the listing without photos. The listing copy is still written for you from the car''s details.
2. The car page and the car''s card show a sample photo, captioned "Sample photo", so renters know it is not this car. Staff see "Using sample photos" on the car and in Listings.
3. Publishing does not wait for a plate check: a sample photo has no plate.
4. Add the real photos when they are taken. Once real photos are approved they replace the sample at once; nothing else to do.

## Sample photos

**Settings** > **Sample photos**. The pictures a car shows until its real photos are in.

1. Every body type has a built-in picture (sedan, SUV, truck, van, coupe, hatchback, electric car).
2. Add your own: choose the Body type, and a Make and Model if the photo is of that exact model, pick the Photo, and press **Add the photo**.
3. The most specific photo wins: make and model, then make and body type, then body type. **Turn off** or **Delete** a photo you no longer want.
4. Cars using sample photos lists the cars still waiting for real photos. Each real car showing sample photos is also a line on To do, with **Add photos**.

![](/guides/img/admin-36-sample-photos-desktop-55c64070.jpg "desktop; size: 1440 812; address: carmacars.ca/admin/settings/sample-photos; pins: 4 26.8 28.9")

## Publish now, and new cars published by themselves

Nothing between a new car and the site has to be finished first: the car goes on the site, and what is still open shows on its checklist.

1. **Settings** > **Program**, **Publish new cars automatically** (on by default): a new real car goes on the site by itself as soon as it has its year, make and model and its rates, when it is added with rates, when its rates are saved, when it is added for an owner, or when an owner''s application is approved.
2. Otherwise open the car: its Listing tab says why it is not on the site and has **Publish now**. A car with no rates yet is published with the suggested rates (similar cars, else the class defaults in Program settings); change them later on the Rates tab.
3. Every real car has its listing from the moment it is added, as a draft. It shows in Listings and in Not on the site yet until it is published.
4. An owner''s own application waits for your decision before its car is published by itself; Publish now still works.
5. A car taken off the site by staff, or scheduled for a later date, is never published by itself: press **Publish now**.

## The checklist: what is still open on a listed car

Open items never stop publishing. They show as warnings on the car''s Listing tab and after Publish now.

| Item | What it means |
| --- | --- |
| Paperwork | Ownership permit, registry forms, agreements signed, Forms C and D, upfront payment, registry visit, tracker, safety certificate |
| Insurance | Not on the fleet insurance policy yet: the car can be booked, but not handed over |
| Details | Colour, body, seats, gearbox: the car page leaves out what is missing |
| Photos | No real photos: sample photos stand in. A photo whose plate is not checked stays private until it is |
| No VIN yet | A car added by its plate alone: add the VIN when you have it |
| Possible duplicate | An open flag in Similar cars. Only Same car keeps the car off the site |
| Owner terms | The management fee (Revenue Share) and fees not set: a request uses the owner''s terms or the standard grid |

## The fleet policy rule at handover

A program owner''s car is listed and can be requested, offered and paid for while its paperwork is open. It is never handed over until the insurer confirms in writing that it is on the fleet insurance policy.

- Staff see a warning on a request and an offer for a car not on the policy yet.
- The handover refuses the car until the insurer''s confirmation is recorded (Owners and onboarding). The field app says so on the job.
- Only real states keep a car off the site: retired, left the program, out of service, Turo only, bookings turned off, a self-managed owner in arrears, or a paused listing.
',
  '<p class="gd-p">Vehicles is the fleet. Listings is the pipeline that turns a car into a page on carmacars.ca: photos, copy, a duplicate check and a covered plate on every public photo.</p><section class="gd-task" id="fleet-and-listings-vehicles" data-gd-task><h2 class="gd-h2">Vehicles</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Vehicles</b></p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Filter by status and mode. Each row shows the plate, class, owner, mode, status, listing and daily rate.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Search by plate, model or owner. <b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Rates for many cars</b> changes the rates of many cars at once.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Open a car for its tabs: Overview, Rates, Fees and coverage, Calendar, Listing, and Owner, documents, tracker.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/vehicles</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/900"><img src="/guides/img/admin-08-vehicles-desktop-46461f49.jpg" alt="" loading="lazy" decoding="async" width="1440" height="900"><span class="gd-pin" style="left:18.5%;top:19.3%" aria-hidden="true">1</span><span class="gd-pin" style="left:83.5%;top:12.9%" aria-hidden="true">2</span><span class="gd-pin" style="left:73.6%;top:38.9%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="fleet-and-listings-set-a-car-s-rates-and-kilometres" data-gd-task><h2 class="gd-h2">Set a car&#39;s rates and kilometres</h2><p class="gd-p">Open the car, then the <b class="gd-ui">Rates</b> tab. Everything on it saves together, in one step.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Type the four rates. Only the daily rate is needed: an empty weekend rate is the daily rate, an empty weekly rate is 6 days at the daily rate, and an empty monthly rate is 22 days.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Kilometres: keep <b class="gd-ui">Use the defaults</b> (the kilometres a day in Settings, Kilometre choices, and the extra kilometre rate in Fee defaults for the car&#39;s class), or choose <b class="gd-ui">Custom for this car</b> and type them.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Check the deposit (the class default is filled in), and the delivery and pickup fees: each is one way, an empty pickup fee is the delivery fee, and 0 means not offered.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Read What renters pay under the fields: real prices for a weekend, a few weekdays, a week and a month, worked out the way bookings are priced. Press <b class="gd-ui">Save the rates</b>.</div></li></ol></div><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Rate</th><th scope="col">What it means</th></tr></thead><tbody><tr><td>Daily rate</td><td>A price per day, for each day that starts on a Sunday, Monday, Tuesday, Wednesday or Thursday</td></tr><tr><td>Weekend rate</td><td>A price per day, not for the whole weekend: each day that starts on a Friday or Saturday. Friday 10 am to Sunday 10 am is 2 days at this rate; Sunday to Monday is a daily day</td></tr><tr><td>Weekly rate</td><td>The price for 7 days. Rentals of 7 to 29 days cost this for each 7 days, counted by the day. A 1 to 6 day rental never costs more</td></tr><tr><td>Monthly rate</td><td>The price for 30 days. A 7 to 29 day rental never costs more</td></tr></tbody></table></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A problem shows on its own field, in words, as you type. When similar cars have rates, a line suggests them with Use these; it is only a hint. The same fields are on <b class="gd-ui">Add a car</b>, so a car can be added with its rates in one pass.</div></aside><aside class="gd-box"><div>Coming soon: The Tracker card on a car says &quot;Coming soon&quot;: live location, the remote immobilize request and mileage from the tracker need the tracker company&#39;s connection first.</div></aside></section><section class="gd-task" id="fleet-and-listings-the-listing-pipeline" data-gd-task><h2 class="gd-h2">The listing pipeline</h2><p class="gd-p">Open <b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Listings</b>. A draft waiting for review shows Needs review.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each row shows the car, plate, state, photos and the pipeline&#39;s progress.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Start a listing</b> to begin one for a car that has none.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Open a car to review it.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/listings</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/560"><img src="/guides/img/admin-09-listings-desktop-970819b6.jpg" alt="" loading="lazy" decoding="async" width="1440" height="560"><span class="gd-pin" style="left:53.5%;top:37%" aria-hidden="true">1</span><span class="gd-pin" style="left:87.2%;top:21.1%" aria-hidden="true">2</span><span class="gd-pin" style="left:32.6%;top:37%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="fleet-and-listings-review-a-listing" data-gd-task><h2 class="gd-h2">Review a listing</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Pipeline shows each step done, such as photo sizes, copy draft and backgrounds.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Similar cars on file lists possible duplicates. Press <b class="gd-ui">Not a duplicate</b> or <b class="gd-ui">Same car</b>. An open flag does not keep the car off the site; only Same car does.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The copy is written by itself from the car&#39;s facts and published when it passes the checks: nothing to type. To change a line, press Change; that field is then locked and kept by every new version.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Under Photos, each public photo shows its plate state: Plate not checked, Plate covered or No plate visible.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/listings/7e43d38d-32bb-4666-a742-81813c3b7671</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1100"><img src="/guides/img/admin-10-listing-review-desktop-352745fd.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1100"><span class="gd-pin" style="left:20.6%;top:16.6%" aria-hidden="true">1</span><span class="gd-pin" style="left:86.1%;top:47.5%" aria-hidden="true">2</span><span class="gd-pin" style="left:19.9%;top:100%" aria-hidden="true">3</span><span class="gd-pin" style="left:74.9%;top:100%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="fleet-and-listings-cover-the-licence-plate" data-gd-task><h2 class="gd-h2">Cover the licence plate</h2><p class="gd-p">On each public photo press <b class="gd-ui">Cover the plate</b>. The editor opens.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The editor suggests a box over the plate. Check it. <b class="gd-ui">Suggest the plate</b> asks again.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Drag over a plate to draw a box. Drag a box to move it, or its corner to resize it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Under Cover the plate with, choose <b class="gd-ui">A CarmaCars plate</b>, <b class="gd-ui">Pixelation</b> or <b class="gd-ui">Blur</b>.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Save the covered photo</b>. <b class="gd-ui">Clear the boxes</b> starts over.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">No plate in the shot? Press <b class="gd-ui">No plate visible on this photo</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/listings/7e43d38d-32bb-4666-a742-81813c3b7671</span></div><div class="gd-imgwrap" style="aspect-ratio:690/703"><img src="/guides/img/admin-11-plate-editor-desktop-4219ad93.jpg" alt="" loading="lazy" decoding="async" width="690" height="703"><span class="gd-pin" style="left:42.5%;top:83.8%" aria-hidden="true">1</span><span class="gd-pin" style="left:49.6%;top:29.9%" aria-hidden="true">2</span><span class="gd-pin" style="left:4.3%;top:77.4%" aria-hidden="true">3</span><span class="gd-pin" style="left:15.5%;top:83.8%" aria-hidden="true">4</span><span class="gd-pin" style="left:18.1%;top:91.2%" aria-hidden="true">5</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The covered photo replaces the public one; the original is kept privately. Keyboard: N adds a box, the arrows move it, Shift and the arrows resize it, Delete removes it.</div></aside></section><section class="gd-task" id="fleet-and-listings-publish" data-gd-task><h2 class="gd-h2">Publish</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A real car that is not on the site is a line on To do: press <b class="gd-ui">Set rates and publish</b>. The daily rate is filled in (the car&#39;s own, or the suggested rate from similar cars or the class); change it if you like and press <b class="gd-ui">Publish now</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">On the car itself, the Listing tab has <b class="gd-ui">Publish now</b>; each open item of its checklist has a button to where it is done.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">From a listing review: press <b class="gd-ui">Approve and publish</b>, <b class="gd-ui">Approve, publish later</b>, or <b class="gd-ui">Send back</b> with what to fix.</div></li></ol></div><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>The plate check never holds a car back: a real photo whose plate is not checked stays private (the other photos, or the sample photos, show instead) and goes public by itself once its plate is covered or marked not visible. Listings already live show &quot;Plate not checked&quot; on such photos.</div></aside></section><section class="gd-task" id="fleet-and-listings-a-listing-without-photos-yet-sample-photos" data-gd-task><h2 class="gd-h2">A listing without photos yet: sample photos</h2><p class="gd-p">A car can be listed before its photos are taken. Until then the site shows a sample photo.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Submit the listing without photos. The listing copy is still written for you from the car&#39;s details.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The car page and the car&#39;s card show a sample photo, captioned &quot;Sample photo&quot;, so renters know it is not this car. Staff see &quot;Using sample photos&quot; on the car and in Listings.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Publishing does not wait for a plate check: a sample photo has no plate.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Add the real photos when they are taken. Once real photos are approved they replace the sample at once; nothing else to do.</div></li></ol></div></section><section class="gd-task" id="fleet-and-listings-sample-photos" data-gd-task><h2 class="gd-h2">Sample photos</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Sample photos</b>. The pictures a car shows until its real photos are in.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Every body type has a built-in picture (sedan, SUV, truck, van, coupe, hatchback, electric car).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Add your own: choose the Body type, and a Make and Model if the photo is of that exact model, pick the Photo, and press <b class="gd-ui">Add the photo</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The most specific photo wins: make and model, then make and body type, then body type. <b class="gd-ui">Turn off</b> or <b class="gd-ui">Delete</b> a photo you no longer want.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Cars using sample photos lists the cars still waiting for real photos. Each real car showing sample photos is also a line on To do, with <b class="gd-ui">Add photos</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings/sample-photos</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/812"><img src="/guides/img/admin-36-sample-photos-desktop-55c64070.jpg" alt="" loading="lazy" decoding="async" width="1440" height="812"><span class="gd-pin" style="left:26.8%;top:28.9%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="fleet-and-listings-publish-now-and-new-cars-published-by-themselves" data-gd-task><h2 class="gd-h2">Publish now, and new cars published by themselves</h2><p class="gd-p">Nothing between a new car and the site has to be finished first: the car goes on the site, and what is still open shows on its checklist.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Program</b>, <b class="gd-ui">Publish new cars automatically</b> (on by default): a new real car goes on the site by itself as soon as it has its year, make and model and its rates, when it is added with rates, when its rates are saved, when it is added for an owner, or when an owner&#39;s application is approved.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Otherwise open the car: its Listing tab says why it is not on the site and has <b class="gd-ui">Publish now</b>. A car with no rates yet is published with the suggested rates (similar cars, else the class defaults in Program settings); change them later on the Rates tab.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Every real car has its listing from the moment it is added, as a draft. It shows in Listings and in Not on the site yet until it is published.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">An owner&#39;s own application waits for your decision before its car is published by itself; Publish now still works.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A car taken off the site by staff, or scheduled for a later date, is never published by itself: press <b class="gd-ui">Publish now</b>.</div></li></ol></div></section><section class="gd-task" id="fleet-and-listings-the-checklist-what-is-still-open-on-a-listed-car" data-gd-task><h2 class="gd-h2">The checklist: what is still open on a listed car</h2><p class="gd-p">Open items never stop publishing. They show as warnings on the car&#39;s Listing tab and after Publish now.</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Item</th><th scope="col">What it means</th></tr></thead><tbody><tr><td>Paperwork</td><td>Ownership permit, registry forms, agreements signed, Forms C and D, upfront payment, registry visit, tracker, safety certificate</td></tr><tr><td>Insurance</td><td>Not on the fleet insurance policy yet: the car can be booked, but not handed over</td></tr><tr><td>Details</td><td>Colour, body, seats, gearbox: the car page leaves out what is missing</td></tr><tr><td>Photos</td><td>No real photos: sample photos stand in. A photo whose plate is not checked stays private until it is</td></tr><tr><td>No VIN yet</td><td>A car added by its plate alone: add the VIN when you have it</td></tr><tr><td>Possible duplicate</td><td>An open flag in Similar cars. Only Same car keeps the car off the site</td></tr><tr><td>Owner terms</td><td>The management fee (Revenue Share) and fees not set: a request uses the owner&#39;s terms or the standard grid</td></tr></tbody></table></div></section><section class="gd-task" id="fleet-and-listings-the-fleet-policy-rule-at-handover" data-gd-task><h2 class="gd-h2">The fleet policy rule at handover</h2><p class="gd-p">A program owner&#39;s car is listed and can be requested, offered and paid for while its paperwork is open. It is never handed over until the insurer confirms in writing that it is on the fleet insurance policy.</p><ul class="gd-ul"><li>Staff see a warning on a request and an offer for a car not on the policy yet.</li><li>The handover refuses the car until the insurer&#39;s confirmation is recorded (Owners and onboarding). The field app says so on the job.</li><li>Only real states keep a car off the site: retired, left the program, out of service, Turo only, bookings turned off, a self-managed owner in arrears, or a paused listing.</li></ul></section>');
select app.guide_release_section('admin', 'partners-company-cars-and-rentals-added-by-hand', 'chapter', 'fleet-and-listings', 'A car comes from one of three places: a program owner, CarmaCars itself, or a partner rental company. You add cars and rentals by hand, retire cars, and delete cars that were added by mistake.

## Add a car

**Cars** > **Vehicles**, then **Add a car**. First choose who supplies it.

1. **A program owner''s car**: choose the owner. The car starts its onboarding (terms, agreements, registry) as if the owner had applied.
2. **CarmaCars-owned (company fleet)**: no owner. All of its revenue is CarmaCars'' and it shows in the company statement as company fleet.
3. **A partner rental company''s car**: choose the partner. Leave the commission empty to use the partner''s, or type one for this car.
4. Type the VIN, the plate and the details.
5. Under Rates and kilometres, type the rates now (only the daily rate is needed) and keep the default kilometres, or leave the rates empty and set them later on the car''s Rates tab. What renters pay shows as you type. Press **Add the car**.

> Tip: The duplicate check runs as for every car: a VIN only once, a plate on one active car, and a likely twin waits for you in Similar cars before it is published.

On a car''s page, **Who supplies the car** shows the supplier and the commission, and changes them. Vehicles filters by supply type.

## Partners

**Owners and partners** > **Partners**. Partner rental companies whose cars we rent out on commission.

1. Press **Add a partner**: business and legal name, contacts, HST number, commission and insurance with its expiry date.
2. Open a partner for its cars, bookings, statements, payouts and documents. A warning shows when its insurance expires soon, and Tasks gets a reminder (Program settings sets how many days before).
3. Banking (Admins only): **Save the payout account** for the account we pay the partner into. The account number is stored encrypted. Press **Verify** once checked.
4. Portal: **Invite to the owner portal** gives the partner the owner portal with its cars, bookings, statements and the partner agreement, filled in and signed on screen in three taps.
5. Signed on paper? Press **Print the partner agreement**, then record the signed scan under Record a paper signature.

## Add a rental by hand

**Bookings** > **Add a rental**. For phone, walk-in, Turo, partner and insurer bookings.

1. Choose the car and the dates. The check shows clashes with other bookings and the cleaning time after each trip. An Admin may book over a clash with a reason.
2. The dates decide the case, shown under them (nothing to tick): a pickup ahead is an upcoming rental, handed over at pickup as usual. A pickup already passed with the return ahead is a rental already underway: it is recorded as on trip from the pickup you enter, on any active car (even one closed to public bookings), and anything a handover checks that is still missing (signature, licence check, coverage proof, deposit, condition report, insurance) becomes a task. A return already passed is a rental that has ended: kept as completed, paid another way or unpaid.
3. Find the renter by name, email or phone, or add a new one: name, email, phone, date of birth and licence. Add any other drivers.
4. Check the price: the car''s rates, extras, coverage and deposit. An Admin may set the price by hand; assistants use the rate sheet and the discounts allowed.
5. A car whose listing is not finished (a draft listing, onboarding, no photos or no rates yet) can be rented at once: it shows Listing not finished in the car list and stays off the public site. With no rates yet, type the rental charge for the whole rental and the reason.
6. An owner''s car that is not on the fleet insurance policy yet: only an Admin adds its rentals, and ticks I checked that this car is insured for this rental. An owner''s car needs its terms (Revenue Share) first. The handover still needs the car to be Available (Overview, Change status).
7. Choose Where it came from and how it is paid: **Paid another way**, **Send a payment link**, **Charge the saved card when the renter signs** or **Unpaid: invoice later**.
8. Press **Check the calendar and the price**. Tick **Do not email the renter** if they should not get the confirmation. Press **Add the rental**.

> Tip: The rental is on the calendars at once (a payment link waits for the payment). The renter signs the rental agreement in their portal, or on paper and you record it. With the saved card, nothing is charged when you add the rental: the card is charged when the renter presses Accept and sign, and until then the rental is awaiting signature. On the booking, **Verified in person** records a licence checked at the counter. A rental already underway can be paid by payment link (the renter signs, then pays from their booking) or the saved card, like an upcoming one.

## Retire or delete a car

**Cars** > **Retire or delete**, or the car''s own page.

1. **Retire this car** takes the car off the site and the calendars and keeps every record. It needs no future confirmed booking. **Restore** brings it back.
2. **Delete this car** removes a car added by mistake, with its photos. Only a car with nothing tied to money (no confirmed or paid booking, payment, statement, toll or damage). Type the plate or the name to confirm.
3. Booking requests that never confirmed and never took money (requested, offered, declined, expired) do not stop a delete. The confirmation lists them; they are removed with the car and a copy is kept. The renters stay on file.
4. On the same page, **Delete all sample cars** deletes every sample car that meets the rule at once, with its requests. Type DELETE SAMPLE CARS to confirm; the ones kept show why, with the booking numbers.

## Sample cars on the site

**Cars** > **Vehicles**, or **Settings** > **Site**. The 20 example cars the site started with, so the fleet never looks empty while the real cars are listed.

1. **Hide sample cars** takes every sample car off the site in one click. Nothing stops it: not an enquiry, not an old request.
2. **Show sample cars** puts the 20 back, with their photos and rates. Ones that were deleted are made again.
3. On the site each one is marked "Example car". They never appear in search engines or the sitemap.
4. A request on a sample car is never a booking. It becomes an enquiry (number EQ-1001 and up) and customer service gets the task Suggest a similar real car.

> Tip: Hide the sample cars once enough real cars are on the site. Delete all sample cars removes them for good.

## Why a car is not on the site yet

**Cars** > **Vehicles**, the card Not on the site yet.

1. Every real car that is not on the site is listed with its next step first: the owner''s signature, the upfront payment, the registry visit, the tracker, the insurer''s confirmation, the rates, the listing review.
2. Do the step named, or ask the person it waits on. The car comes off the list once it is on the site.
3. A car without photos is marked sample photos: once listed it shows a sample photo until its real photos are approved.

## Tolls when two rentals overlap

Bookings held for an insurer and other placeholders are never matched to a toll. When two real rentals overlap the toll time, nobody is charged automatically: the toll waits in the work queue under Two rentals, with both bookings, and you choose who pays.
', 'Partners, company cars and rentals added by hand', 'Add a car, partners, add a rental, retire or delete a car, sample cars and tolls with two rentals.',
  'A car comes from one of three places: a program owner, CarmaCars itself, or a partner rental company. You add cars and rentals by hand, retire cars, and delete cars that were added by mistake.

## Add a car

**Cars** > **Vehicles**, then **Add a car**. Start with the VIN: everything else about the car comes from it.

1. Type or paste the VIN. At the 17th character the car is looked up: one line shows the year, make, model, trim, body, seats, doors, fuel, drive, gearbox and engine. Press Edit only if something is wrong.
2. No VIN at hand? Press **No VIN at hand? Add the car by its plate** and choose the year, make and model from the lists. The VIN can be added later; the details fill in then.
3. Tap the colour (it is not in the VIN). Leave it empty and it is read from the cover photo once the car has one.
4. Check the class. It is set from the make, model, body and age (a 2016 Porsche Macan is Premium, an SUV is SUV) and the line under it says why. Change it if it is wrong.
5. Choose who supplies it: **A program owner''s car** (choose the owner; the car starts its onboarding), **CarmaCars-owned (company fleet)** (no owner; all of its revenue is CarmaCars'') or **A partner rental company''s car** (choose the partner; leave the commission empty to use the partner''s).
6. The daily rate is filled in from similar cars, else the class. Keep it, change it, or empty it and set the rates later on the car''s Rates tab. Press **Add the car**.

> Tip: The title, description and features are written by themselves right after the car is added, from the VIN details. Change any of them on the car''s listing; a field you change is kept.

> Good to know: Every car gets a fleet number and its standard settings the moment it is added: a complete rate card (the daily rate you typed or the suggested one, weekend, weekly and monthly from it, the kilometres a day, the extra kilometre rate, the deposit and the delivery and pickup fee of its class) and drivers 18 to 20 allowed. Each value set this way says (Set automatically) on the car''s Overview and Rates tab until you change it. The defaults come from Settings: Program and Fee defaults.

> Tip: A VIN that does not add up (one character misread) shows a warning; you can still save it. A VIN the decoder cannot read asks only the year, make and model and never stops you: the details fill in when it is read later. The duplicate check runs as for every car: a VIN only once, a plate on one active car, and a likely twin waits for you in Similar cars before it is published.

On a car''s page, **Who supplies the car** shows the supplier and the commission, and changes them. Vehicles filters by supply type.

## Partners

**Owners and partners** > **Partners**. Partner rental companies whose cars we rent out on commission.

1. Press **Add a partner**: business and legal name, contacts, HST number, commission and insurance with its expiry date.
2. Open a partner for its cars, bookings, statements, payouts and documents. A warning shows when its insurance expires soon, and Tasks gets a reminder (Program settings sets how many days before).
3. Banking (Admins only): **Save the payout account** for the account we pay the partner into. The account number is stored encrypted. Press **Verify** once checked.
4. Portal: **Invite to the owner portal** gives the partner the owner portal with its cars, bookings, statements and the partner agreement, filled in and signed on screen in three taps.
5. Signed on paper? Press **Print the partner agreement**, then record the signed scan under Record a paper signature.

## Add a rental by hand

**Bookings** > **Add a rental**. For phone, walk-in, Turo, partner and insurer bookings.

1. Choose the car and the dates. The check shows clashes with other bookings and the cleaning time after each trip. An Admin may book over a clash with a reason.
2. The dates decide the case, shown under them (nothing to tick): a pickup ahead is an upcoming rental, handed over at pickup as usual. A pickup already passed with the return ahead is a rental already underway: it is recorded as on trip from the pickup you enter, on any active car (even one closed to public bookings), and anything a handover checks that is still missing (signature, licence check, coverage proof, deposit, condition report, insurance) becomes a task. A return already passed is a rental that has ended: kept as completed, paid another way or unpaid.
3. Find the renter by name, email or phone, or add a new one: name, email, phone, date of birth and licence. Add any other drivers.
4. Check the price: the car''s rates, extras, coverage and deposit. An Admin may set the price by hand; assistants use the rate sheet and the discounts allowed.
5. A car whose listing is not finished (a draft listing, onboarding, no photos or no rates yet) can be rented at once: it shows Listing not finished in the car list and stays off the public site. With no rates yet, type the rental charge for the whole rental and the reason.
6. An owner''s car that is not on the fleet insurance policy yet: only an Admin adds its rentals, and ticks I checked that this car is insured for this rental. An owner''s car needs its terms (Revenue Share) first. The handover still needs the car on the fleet policy: press **Insurer confirmed** once the insurer confirms it.
7. Choose Where it came from and how it is paid: **Paid another way**, **Send a payment link**, **Charge the saved card when the renter signs** or **Unpaid: invoice later**.
8. Press **Check the calendar and the price**. Tick **Do not email the renter** if they should not get the confirmation. Press **Add the rental**.

> Tip: The rental is on the calendars at once (a payment link waits for the payment). The renter signs the rental agreement in their portal, or on paper and you record it. With the saved card, nothing is charged when you add the rental: the card is charged when the renter presses Accept and sign, and until then the rental is awaiting signature. On the booking, **Verified in person** records a licence checked at the counter. A rental already underway can be paid by payment link (the renter signs, then pays from their booking) or the saved card, like an upcoming one.

## Retire or delete a car

**Cars** > **Retire or delete**, or the car''s own page.

1. **Retire this car** takes the car off the site and the calendars and keeps every record. It needs no future confirmed booking. **Restore** brings it back.
2. **Delete this car** removes a car added by mistake, with its photos. Only a car with nothing tied to money (no confirmed or paid booking, payment, statement, toll or damage). Type the plate or the name to confirm.
3. Booking requests that never confirmed and never took money (requested, offered, declined, expired) do not stop a delete. The confirmation lists them; they are removed with the car and a copy is kept. The renters stay on file.
4. On the same page, **Delete all sample cars** deletes every sample car that meets the rule at once, with its requests. Type DELETE SAMPLE CARS to confirm; the ones kept show why, with the booking numbers.

## Sample cars on the site

**Cars** > **Vehicles**, or **Settings** > **Site**. The 20 example cars the site started with, so the fleet never looks empty while the real cars are listed.

1. **Hide sample cars** takes every sample car off the site in one click. Nothing stops it: not an enquiry, not an old request.
2. **Show sample cars** puts the 20 back, with their photos and rates. Ones that were deleted are made again.
3. On the site each one is marked "Example car". They never appear in search engines or the sitemap.
4. A request on a sample car is never a booking. It becomes an enquiry (number EQ-1001 and up) and customer service gets the task Suggest a similar real car.

> Tip: Hide the sample cars once enough real cars are on the site. Delete all sample cars removes them for good.

## Why a car is not on the site yet

**Cars** > **Vehicles**, the card Not on the site yet.

1. Every real car that is not on the site is listed with its next step first: the rates, Publish now, the listing review.
2. The same car is a line on To do with **Set rates and publish**. The car comes off both once it is on the site.
3. A car without photos is marked sample photos: once listed it shows a sample photo until its real photos are approved.

## Tolls when two rentals overlap

Bookings held for an insurer and other placeholders are never matched to a toll. When two real rentals overlap the toll time, nobody is charged automatically: the toll waits in the work queue under Two rentals, with both bookings, and you choose who pays.
',
  '<p class="gd-p">A car comes from one of three places: a program owner, CarmaCars itself, or a partner rental company. You add cars and rentals by hand, retire cars, and delete cars that were added by mistake.</p><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-add-a-car" data-gd-task><h2 class="gd-h2">Add a car</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Vehicles</b>, then <b class="gd-ui">Add a car</b>. Start with the VIN: everything else about the car comes from it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Type or paste the VIN. At the 17th character the car is looked up: one line shows the year, make, model, trim, body, seats, doors, fuel, drive, gearbox and engine. Press Edit only if something is wrong.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">No VIN at hand? Press <b class="gd-ui">No VIN at hand? Add the car by its plate</b> and choose the year, make and model from the lists. The VIN can be added later; the details fill in then.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Tap the colour (it is not in the VIN). Leave it empty and it is read from the cover photo once the car has one.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Check the class. It is set from the make, model, body and age (a 2016 Porsche Macan is Premium, an SUV is SUV) and the line under it says why. Change it if it is wrong.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Choose who supplies it: <b class="gd-ui">A program owner&#39;s car</b> (choose the owner; the car starts its onboarding), <b class="gd-ui">CarmaCars-owned (company fleet)</b> (no owner; all of its revenue is CarmaCars&#39;) or <b class="gd-ui">A partner rental company&#39;s car</b> (choose the partner; leave the commission empty to use the partner&#39;s).</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">The daily rate is filled in from similar cars, else the class. Keep it, change it, or empty it and set the rates later on the car&#39;s Rates tab. Press <b class="gd-ui">Add the car</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The title, description and features are written by themselves right after the car is added, from the VIN details. Change any of them on the car&#39;s listing; a field you change is kept.</div></aside><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Every car gets a fleet number and its standard settings the moment it is added: a complete rate card (the daily rate you typed or the suggested one, weekend, weekly and monthly from it, the kilometres a day, the extra kilometre rate, the deposit and the delivery and pickup fee of its class) and drivers 18 to 20 allowed. Each value set this way says (Set automatically) on the car&#39;s Overview and Rates tab until you change it. The defaults come from Settings: Program and Fee defaults.</div></aside><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A VIN that does not add up (one character misread) shows a warning; you can still save it. A VIN the decoder cannot read asks only the year, make and model and never stops you: the details fill in when it is read later. The duplicate check runs as for every car: a VIN only once, a plate on one active car, and a likely twin waits for you in Similar cars before it is published.</div></aside><p class="gd-p">On a car&#39;s page, <b class="gd-ui">Who supplies the car</b> shows the supplier and the commission, and changes them. Vehicles filters by supply type.</p></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-partners" data-gd-task><h2 class="gd-h2">Partners</h2><p class="gd-p"><b class="gd-ui">Owners and partners</b> &gt; <b class="gd-ui">Partners</b>. Partner rental companies whose cars we rent out on commission.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Add a partner</b>: business and legal name, contacts, HST number, commission and insurance with its expiry date.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open a partner for its cars, bookings, statements, payouts and documents. A warning shows when its insurance expires soon, and Tasks gets a reminder (Program settings sets how many days before).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Banking (Admins only): <b class="gd-ui">Save the payout account</b> for the account we pay the partner into. The account number is stored encrypted. Press <b class="gd-ui">Verify</b> once checked.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Portal: <b class="gd-ui">Invite to the owner portal</b> gives the partner the owner portal with its cars, bookings, statements and the partner agreement, filled in and signed on screen in three taps.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Signed on paper? Press <b class="gd-ui">Print the partner agreement</b>, then record the signed scan under Record a paper signature.</div></li></ol></div></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-add-a-rental-by-hand" data-gd-task><h2 class="gd-h2">Add a rental by hand</h2><p class="gd-p"><b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Add a rental</b>. For phone, walk-in, Turo, partner and insurer bookings.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Choose the car and the dates. The check shows clashes with other bookings and the cleaning time after each trip. An Admin may book over a clash with a reason.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The dates decide the case, shown under them (nothing to tick): a pickup ahead is an upcoming rental, handed over at pickup as usual. A pickup already passed with the return ahead is a rental already underway: it is recorded as on trip from the pickup you enter, on any active car (even one closed to public bookings), and anything a handover checks that is still missing (signature, licence check, coverage proof, deposit, condition report, insurance) becomes a task. A return already passed is a rental that has ended: kept as completed, paid another way or unpaid.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Find the renter by name, email or phone, or add a new one: name, email, phone, date of birth and licence. Add any other drivers.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Check the price: the car&#39;s rates, extras, coverage and deposit. An Admin may set the price by hand; assistants use the rate sheet and the discounts allowed.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A car whose listing is not finished (a draft listing, onboarding, no photos or no rates yet) can be rented at once: it shows Listing not finished in the car list and stays off the public site. With no rates yet, type the rental charge for the whole rental and the reason.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">An owner&#39;s car that is not on the fleet insurance policy yet: only an Admin adds its rentals, and ticks I checked that this car is insured for this rental. An owner&#39;s car needs its terms (Revenue Share) first. The handover still needs the car on the fleet policy: press <b class="gd-ui">Insurer confirmed</b> once the insurer confirms it.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Choose Where it came from and how it is paid: <b class="gd-ui">Paid another way</b>, <b class="gd-ui">Send a payment link</b>, <b class="gd-ui">Charge the saved card when the renter signs</b> or <b class="gd-ui">Unpaid: invoice later</b>.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Press <b class="gd-ui">Check the calendar and the price</b>. Tick <b class="gd-ui">Do not email the renter</b> if they should not get the confirmation. Press <b class="gd-ui">Add the rental</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The rental is on the calendars at once (a payment link waits for the payment). The renter signs the rental agreement in their portal, or on paper and you record it. With the saved card, nothing is charged when you add the rental: the card is charged when the renter presses Accept and sign, and until then the rental is awaiting signature. On the booking, <b class="gd-ui">Verified in person</b> records a licence checked at the counter. A rental already underway can be paid by payment link (the renter signs, then pays from their booking) or the saved card, like an upcoming one.</div></aside></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-retire-or-delete-a-car" data-gd-task><h2 class="gd-h2">Retire or delete a car</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Retire or delete</b>, or the car&#39;s own page.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Retire this car</b> takes the car off the site and the calendars and keeps every record. It needs no future confirmed booking. <b class="gd-ui">Restore</b> brings it back.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Delete this car</b> removes a car added by mistake, with its photos. Only a car with nothing tied to money (no confirmed or paid booking, payment, statement, toll or damage). Type the plate or the name to confirm.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Booking requests that never confirmed and never took money (requested, offered, declined, expired) do not stop a delete. The confirmation lists them; they are removed with the car and a copy is kept. The renters stay on file.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">On the same page, <b class="gd-ui">Delete all sample cars</b> deletes every sample car that meets the rule at once, with its requests. Type DELETE SAMPLE CARS to confirm; the ones kept show why, with the booking numbers.</div></li></ol></div></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-sample-cars-on-the-site" data-gd-task><h2 class="gd-h2">Sample cars on the site</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Vehicles</b>, or <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Site</b>. The 20 example cars the site started with, so the fleet never looks empty while the real cars are listed.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Hide sample cars</b> takes every sample car off the site in one click. Nothing stops it: not an enquiry, not an old request.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Show sample cars</b> puts the 20 back, with their photos and rates. Ones that were deleted are made again.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">On the site each one is marked &quot;Example car&quot;. They never appear in search engines or the sitemap.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A request on a sample car is never a booking. It becomes an enquiry (number EQ-1001 and up) and customer service gets the task Suggest a similar real car.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Hide the sample cars once enough real cars are on the site. Delete all sample cars removes them for good.</div></aside></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-why-a-car-is-not-on-the-site-yet" data-gd-task><h2 class="gd-h2">Why a car is not on the site yet</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Vehicles</b>, the card Not on the site yet.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Every real car that is not on the site is listed with its next step first: the rates, Publish now, the listing review.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The same car is a line on To do with <b class="gd-ui">Set rates and publish</b>. The car comes off both once it is on the site.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A car without photos is marked sample photos: once listed it shows a sample photo until its real photos are approved.</div></li></ol></div></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-tolls-when-two-rentals-overlap" data-gd-task><h2 class="gd-h2">Tolls when two rentals overlap</h2><p class="gd-p">Bookings held for an insurer and other placeholders are never matched to a toll. When two real rentals overlap the toll time, nobody is charged automatically: the toll waits in the work queue under Two rentals, with both bookings, and you choose who pays.</p></section>');
select app.guide_release_section('admin', 'owners-and-onboarding', 'chapter', 'partners-company-cars-and-rentals-added-by-hand', 'Owners apply on the site with List your car. Every application waits for you in one place, Applications: approve it, ask the owner for something, or decline it. Approved owners sign and pay in their portal.

## Applications

**Owners and partners** > **Applications**. Every owner application, newest first.

1. The chips filter by status: New, Waiting on owner, Approved, Declined, or All. New applications also show on To do.
2. Each row shows the application number, the owner, the car, how many of the four checks are done, and when they applied.
3. Open an application to decide.

![](/guides/img/admin-33-applications-desktop-152f9e34.jpg "desktop; size: 1440 640; address: carmacars.ca/admin/applications; pins: 1 36.8 39.7, 2 48.6 53.1, 3 19.8 53.1")

## Decide on an application

One page holds everything: the owner, the car, the uploads, the four checks and the notes.

1. Check the driver''s licence, the ownership, the insurance and the lender or lessor. Mark each one Checked, fine, Problem or Not needed.
2. Press **Approve**. The step "Terms and first invoice" opens for each car, filled in with the owner''s negotiated terms (or the standard grid): Insurance Fee, Tracker Fee, Revenue Share, Install Fee and the first and last month amount (2 x the Insurance Fee unless you type an exact amount). Change any of them to the cent.
3. Choose the invoices: First and last month, Registration fee (any exact amount), Tracker install (only once trackers are available) and Another invoice. For each one choose Send now, Save as draft or Already paid. Already paid asks how (e-Transfer, cash, cheque, bank transfer or other), the date and the reference: it is recorded like Record payment and the owner gets the receipt, not an invoice.
4. Press **Approve** at the bottom of the step. Nothing is set or sent before that. The owner becomes active, the documents open for one signature in their portal, only the invoices you chose are made, and the owner gets one email.
5. Missing something? Press **Ask for something**, tick what you need (for example the ownership permit or the insurance slip), add a message if you like, and press **Send to the owner**. The owner gets an email and a task in their portal; the application shows Waiting on owner until they answer.
6. Not a fit? Press **Decline**, write the Reason the owner reads, and press **Decline the application**. The owner is emailed for each car.

![](/guides/img/admin-34-application-desktop-98b64f92.jpg "desktop; size: 1440 812; address: carmacars.ca/admin/applications/166e487a-11a1-4433-b1ca-8c2bc14bf5ca; pins: 1 72.9 67.1, 2 73.9 42.9, 3 84.7 42.9, 4 72.9 49.6")

The application has an Invoices tab: every invoice of its cars, drafts and voids included. An application staff entered for the owner says "Entered by staff" and who; approving it sends the owner the set-up email (review the details and sign) instead of the approval email.

> Tip: Notes on the page are for staff only: **Add note** keeps a line on the record. When the owner answers a request, their answer is in the notes and the application is New again.

## Add a car for an owner

**Owners and partners** > **Add a car for an owner**, or **Add another car** on an owner''s page. The owner never has to fill in the application.

1. The owner: find them by name, email or phone, or choose New owner and enter the name, email, phone and address.
2. The car: type the VIN and press Decode, then the plate, colour, odometer, insurer and whether it is owned, financed or leased. Photos are optional: the listing shows sample photos until real ones are added. Upload the ownership permit, the insurance slip and the lender''s information if you have them.
3. Terms and first invoice: the same fields as Approve. For another car of the same owner they start from that owner''s terms.
4. Who sourced the owner: Entered for CarmaCars, or I sourced this owner (only then are you recorded as the one who brought the owner). How the owner signs: by email, or on paper.
5. Press **Add the car and set it up**. The owner gets one email: review the details, correct anything, and sign. An owner with no sign-in gets the link to choose a password in that same email.

Customer service and fleet assistants add cars the same way from their portal; theirs wait in Applications for you, with the terms and invoices they proposed already filled in. On an approved application staff entered, **Send the set-up email again** sends the owner the email with a fresh link.

## Owners

**Owners and partners** > **Owners**. Every owner, with their cars and where onboarding stands.

1. Each owner shows their application, how many cars, and where onboarding stands.
2. **View as (owner portal)** shows their portal. **Send password link** helps them sign in.
3. Invite an owner on file: fill in Name and Email under Invite an owner, then press **Send invitation**.

![](/guides/img/admin-12-owners-desktop-3a54d505.jpg "desktop; size: 1440 560; address: carmacars.ca/admin/owners; pins: 1 41.0 42.9, 2 37.4 49.3, 3 77.4 82.5")

The owner signs everything at once in their portal (Check and sign: the agreements, schedules, Forms A and B and the official forms that are ready). The confirmations to tick, then one signature: CarmaCars countersigns at the same moment, under the signing officer''s standing authorization. A car with a second owner on the ownership waits for that owner too: they get their own link by email and sign the same documents.

## An owner''s page

Open an owner from Owners. Three tabs: Overview, Terms and Invoices. **Add another car** and **New invoice** sit under the name.

1. Upfront invoices: issue the first and last month amount agreed on each car''s terms, for each car whose terms are set.
2. Owner: address, sign-in, agreements, and what is still missing for the registry forms.
3. Statements and payouts for this owner.
4. Forms C and D, with a link to the review queue.
5. Further down: **View as (owner portal)**, **Send password link** and **Send a sign-in link to the owner portal**.

![](/guides/img/admin-13-owner-desktop-819a9f8b.jpg "desktop; size: 410 1030; address: carmacars.ca/admin/owners/9e367055-7780-4451-822a-d79d5b59a309; pins: 1 24.6 4.4, 2 16.1 32.9, 3 31.5 73.2, 4 21.2 98.1")

## An owner''s terms

The Terms tab of an owner''s page: what the owner pays and keeps, exact to the cent.

1. The owner''s terms are the default for their cars: fill in what you negotiated (leave a field empty to keep the standard grid), the date it applies from, and press **Save the terms**. They apply to cars whose terms are set from that date.
2. Each car has its own terms: open Change this car''s terms, type the exact amounts and press **Save the terms**. While the Vehicle Schedule is not signed, the schedule changes at once and the documents are made again.
3. When the Vehicle Schedule is already signed, saving shows a warning: the owner must sign an updated schedule. Press **Create the updated schedule and email the owner to sign**. The current terms stay until the owner signs; then the new ones apply from their date to invoices, debits and statements.
4. Signed on paper instead? **Record signed on paper** with the date. **Withdraw it** cancels the update, with a reason.

## Paid and signed

**Owners and partners** > **Paid and signed**. What each owner still has to pay or sign, and how each item was done.

1. Each owner shows how many items are open and how many are done. Owners with nothing left are hidden; press Show every owner to see them.
2. Open **Checklist and quick actions**. Each line says Signed in the portal, Signed on paper, Paid by e-Transfer, Not signed, and so on.
3. Paid by e-Transfer, cheque, cash or bank transfer? Press **Record payment**. Choose Paid by, the Date received and the Reference (the cheque number for a cheque). Leave Amount empty for the full balance, or type less for a partial payment. Add a photo of the cheque or a screenshot if you have one.
4. Signed on paper? Press **Record paper signature**. Choose the Document, check Signed by and Date signed, add the witnesses where the form needs them, and upload the scan of every signed page.
5. The same checklist sits at the top of each owner''s page.

A recorded payment marks the invoice paid (or partly paid), stops the automatic debit for that amount, sends the owner a receipt, and shows "Paid by e-Transfer on " in their portal. A paper signature counts as signed everywhere: the checklist, onboarding and the owner portal. The scan is kept privately with the owner''s documents.

> Watch out: Recorded the wrong thing, or a cheque bounced? Press **Void** beside it and give the reason. The invoice owes that amount again and the owner is told; a voided signature makes the item open again. Only an Admin can void.

## Forms C and D

**Owners and partners** > **Owner forms**. Form C is signed on screen in the owner portal, with the witness on the same screen. Form D (and Form C on paper, if the owner prefers) is printed, signed in front of witnesses, and sent as a photo of each page.

1. Each row shows the owner, the form, the witnesses and when it was uploaded.
2. Press Open to read the photo or scan. Check each marked spot is signed or initialled.
3. Press **Approve**, or **Send back** with What to fix (the owner reads this).

![](/guides/img/admin-22-owner-forms-desktop-c20ad300.jpg "desktop; size: 1440 470; address: carmacars.ca/admin/owner-forms; pins: 1 29.2 52.3, 2 57.6 52.3, 3 76.7 52.3")
', 'Owners and onboarding', 'Applications, the terms and first invoice, adding a car for an owner, an owner''s terms and invoices, paid and signed, and Forms C and D.',
  'Owners apply on the site with List your car. Every application waits for you in one place, Applications: approve it, ask the owner for something, or decline it. Approved owners sign and pay in their portal.

## Applications

**Owners and partners** > **Applications**. Every owner application, newest first.

1. The chips filter by status: New, Waiting on owner, Approved, Declined, or All. New applications also show on To do.
2. Each row shows the application number, the owner, the car, how many of the four checks are done, and when they applied.
3. Open an application to decide.

![](/guides/img/admin-33-applications-desktop-152f9e34.jpg "desktop; size: 1440 640; address: carmacars.ca/admin/applications; pins: 1 36.8 39.7, 2 48.6 53.1, 3 19.8 53.1")

## Decide on an application

One page holds everything: the owner, the car, the uploads, the four checks and the notes.

1. Check the driver''s licence, the ownership, the insurance and the lender or lessor. Mark each one Checked, fine, Problem or Not needed.
2. Press **Approve**. The step "Terms and first invoice" opens for each car, filled in with the owner''s negotiated terms (or the standard grid): Insurance Fee, Tracker Fee, management fee (Revenue Share), Install Fee and the first and last month amount (2 x the Insurance Fee unless you type an exact amount). Change any of them to the cent.
3. Choose the invoices: First and last month, Registration fee (any exact amount), Tracker install (only once trackers are available) and Another invoice. For each one choose Send now, Save as draft or Already paid. Already paid asks how (e-Transfer, cash, cheque, bank transfer or other), the date and the reference: it is recorded like Record payment and the owner gets the receipt, not an invoice.
4. Press **Approve** at the bottom of the step. Nothing is set or sent before that. The owner becomes active, the documents open for one signature in their portal, only the invoices you chose are made, and the owner gets one email.
5. Missing something? Press **Ask for something**, tick what you need (for example the ownership permit or the insurance slip), add a message if you like, and press **Send to the owner**. The owner gets an email and a task in their portal; the application shows Waiting on owner until they answer.
6. Not a fit? Press **Decline**, write the Reason the owner reads, and press **Decline the application**. The owner is emailed for each car.

![](/guides/img/admin-34-application-desktop-98b64f92.jpg "desktop; size: 1440 812; address: carmacars.ca/admin/applications/166e487a-11a1-4433-b1ca-8c2bc14bf5ca; pins: 1 72.9 67.1, 2 73.9 42.9, 3 84.7 42.9, 4 72.9 49.6")

The application has an Invoices tab: every invoice of its cars, drafts and voids included. An application staff entered for the owner says "Entered by staff" and who; approving it sends the owner the set-up email (review the details and sign) instead of the approval email.

> Tip: Notes on the page are for staff only: **Add note** keeps a line on the record. When the owner answers a request, their answer is in the notes and the application is New again.

## Add a car for an owner

**Owners and partners** > **Add a car for an owner**, or **Add another car** on an owner''s page. The owner never has to fill in the application.

1. The owner: find them by name, email or phone, or choose New owner and enter the name, email, phone and address.
2. The car: type the VIN. The car is looked up at once and shown in one line (Edit if something is wrong); no VIN at hand, add it by its plate with the year, make and model from the lists. Tap the colour, check the class, then the odometer, insurer and whether it is owned, financed or leased. Photos are optional: the listing shows sample photos until real ones are added. Upload the ownership permit, the insurance slip and the lender''s information if you have them.
3. Terms and first invoice: the same fields as Approve. For another car of the same owner they start from that owner''s terms.
4. Who sourced the owner: Entered for CarmaCars, or I sourced this owner (only then are you recorded as the one who brought the owner). How the owner signs: by email, or on paper.
5. Press **Add the car and set it up**. The owner gets one email: review the details, correct anything, and sign. An owner with no sign-in gets the link to choose a password in that same email.

Customer service and fleet assistants add cars the same way from their portal; theirs wait in Applications for you, with the terms and invoices they proposed already filled in. On an approved application staff entered, **Send the set-up email again** sends the owner the email with a fresh link.

## Owners

**Owners and partners** > **Owners**. Every owner, with their cars and where onboarding stands.

1. Each owner shows their application, how many cars, and where onboarding stands.
2. **View as (owner portal)** shows their portal. **Send password link** helps them sign in.
3. Invite an owner on file: fill in Name and Email under Invite an owner, then press **Send invitation**.

![](/guides/img/admin-12-owners-desktop-3a54d505.jpg "desktop; size: 1440 560; address: carmacars.ca/admin/owners; pins: 1 41.0 42.9, 2 37.4 49.3, 3 77.4 82.5")

The owner signs everything at once in their portal (Check and sign: the agreements, schedules, Forms A and B and the official forms that are ready). The confirmations to tick, then one signature: CarmaCars countersigns at the same moment, under the signing officer''s standing authorization. A car with a second owner on the ownership waits for that owner too: they get their own link by email and sign the same documents.

## Mark a car insured (Insurer confirmed)

A program owner''s car is handed over to a renter only once the insurer confirms in writing that it is on the fleet policy. Requests, offers and payment never wait for it.

1. Each car waiting for the insurer is a line on To do: "Insurer has not confirmed : mark it insured". It says Now when a booking picks the car up soon.
2. When the insurer''s email arrives, press **Mark insured**. The date is today; change it to the date of the insurer''s email if it was earlier. Add its subject as the Reference if you like, and press **Insurer confirmed**.
3. One email for several cars? Press **Mark several insured** on the line " cars wait for the insurer". Every waiting car is ticked: untick any car the insurer did not name, check the date, and confirm them all at once.
4. The same button is on the car: Overview (**Insurer confirmed**) and the Listing tab''s checklist, item "Not on the fleet insurance policy yet".

The car is then on the fleet policy from that date: it can be handed over, its Enrollment Date is that date, its fee terms start, and the owner gets the email "Written confirmation: your car is on the fleet policy". Its paperwork (agreements, registry visit, tracker) stays on its checklist until done. A car already listed and Available stays Available.

## Owners who paid another way, and the terms you agreed

Two lines on To do keep an owner''s money right without opening their page.

1. "Record the first and last month paid by ": their first and last month invoice was voided and nothing paid is recorded. Press **Record what they paid**, type the amount for each car (tax included), or one total for several cars, how and when it was paid and the reference. A draft first and last month invoice is kept or voided, your choice. Each car''s invoice is then marked paid, the owner gets the receipt and the two prepaid months count. Never for a shareholder.
2. "Enter the terms agreed with ": their cars still use the standard grid. Press **Enter the terms**: the Management fee (Revenue Share), the Insurance Fee, the Tracker Fee, the Install Fee and the first and last month are filled in from the grid. Type what you agreed for the owner, and open a car to give it its own. A car whose schedule is signed gets an updated schedule for the owner to sign.
3. Nothing to change? Press **Not needed** or **These are correct**: the line does not come back.

## A shareholder''s own car

On the owner''s page, each car has **Shareholder’s own car**.

1. A shareholder''s own car is split 90/10 (the share in Program settings) and pays no Insurance Fee, Tracker Fee, first and last month or tracker install.
2. Press **Shareholder’s own car**, say why (it is kept in the audit log) and confirm. Press it again to undo. Bookings already made keep their split.
3. A first and last month or a tracker install invoice is refused for such a car, from any screen.

## Cancellation refunds

**Settings** > **Program**: the refund for each cancellation tier.

| When the renter cancels | Refund (default) |
| --- | --- |
| Within 24 hours of booking, 48 hours or more before the start | 95% |
| 48 hours or more before the start | 75% |
| 24 to 48 hours before the start | 50% |
| Under 24 hours, or after the start | 0% |

## An owner''s page

Open an owner from Owners. Three tabs: Overview, Terms and Invoices. **Add another car** and **New invoice** sit under the name.

1. Upfront invoices: issue the first and last month amount agreed on each car''s terms, for each car whose terms are set.
2. Owner: address, sign-in, agreements, and what is still missing for the registry forms.
3. Statements and payouts for this owner.
4. Forms C and D, with a link to the review queue.
5. Further down: **View as (owner portal)**, **Send password link** and **Send a sign-in link to the owner portal**.

![](/guides/img/admin-13-owner-desktop-819a9f8b.jpg "desktop; size: 410 1030; address: carmacars.ca/admin/owners/9e367055-7780-4451-822a-d79d5b59a309; pins: 1 24.6 4.4, 2 16.1 32.9, 3 31.5 73.2, 4 21.2 98.1")

## An owner''s terms

The Terms tab of an owner''s page: what the owner pays and keeps, exact to the cent.

1. The owner''s terms are the default for their cars: fill in what you negotiated (leave a field empty to keep the standard grid), the date it applies from, and press **Save the terms**. They apply to cars whose terms are set from that date.
2. Each car has its own terms: open Change this car''s terms, type the exact amounts and press **Save the terms**. While the Vehicle Schedule is not signed, the schedule changes at once and the documents are made again.
3. When the Vehicle Schedule is already signed, saving shows a warning: the owner must sign an updated schedule. Press **Create the updated schedule and email the owner to sign**. The current terms stay until the owner signs; then the new ones apply from their date to invoices, debits and statements.
4. Signed on paper instead? **Record signed on paper** with the date. **Withdraw it** cancels the update, with a reason.

## Paid and signed

**Owners and partners** > **Paid and signed**. What each owner still has to pay or sign, and how each item was done.

1. Each owner shows how many items are open and how many are done. Owners with nothing left are hidden; press Show every owner to see them.
2. Open **Checklist and quick actions**. Each line says Signed in the portal, Signed on paper, Paid by e-Transfer, Not signed, and so on.
3. Paid by e-Transfer, cheque, cash or bank transfer? Press **Record payment**. Choose Paid by, the Date received and the Reference (the cheque number for a cheque). Leave Amount empty for the full balance, or type less for a partial payment. Add a photo of the cheque or a screenshot if you have one.
4. Signed on paper? Press **Record paper signature**. Choose the Document, check Signed by and Date signed, add the witnesses where the form needs them, and upload the scan of every signed page.
5. The same checklist sits at the top of each owner''s page.
6. You rarely need to come here: an upfront or overdue owner invoice is a line on To do with **Record payment**, and an owner whose documents were sent two days ago or more and are not signed is a line with **Record paper signature**. Both pop-ups are the same forms, filled in.

A recorded payment marks the invoice paid (or partly paid), stops the automatic debit for that amount, sends the owner a receipt, and shows "Paid by e-Transfer on " in their portal. A paper signature counts as signed everywhere: the checklist, onboarding and the owner portal. The scan is kept privately with the owner''s documents.

> Watch out: Recorded the wrong thing, or a cheque bounced? Press **Void** beside it and give the reason. The invoice owes that amount again and the owner is told; a voided signature makes the item open again. Only an Admin can void.

## Forms C and D

**Owners and partners** > **Owner forms**. Form C is signed on screen in the owner portal, with the witness on the same screen. Form D (and Form C on paper, if the owner prefers) is printed, signed in front of witnesses, and sent as a photo of each page.

1. Each row shows the owner, the form, the witnesses and when it was uploaded.
2. Press Open to read the photo or scan. Check each marked spot is signed or initialled.
3. Press **Approve**, or **Send back** with What to fix (the owner reads this).

![](/guides/img/admin-22-owner-forms-desktop-c20ad300.jpg "desktop; size: 1440 470; address: carmacars.ca/admin/owner-forms; pins: 1 29.2 52.3, 2 57.6 52.3, 3 76.7 52.3")
',
  '<p class="gd-p">Owners apply on the site with List your car. Every application waits for you in one place, Applications: approve it, ask the owner for something, or decline it. Approved owners sign and pay in their portal.</p><section class="gd-task" id="owners-and-onboarding-applications" data-gd-task><h2 class="gd-h2">Applications</h2><p class="gd-p"><b class="gd-ui">Owners and partners</b> &gt; <b class="gd-ui">Applications</b>. Every owner application, newest first.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The chips filter by status: New, Waiting on owner, Approved, Declined, or All. New applications also show on To do.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each row shows the application number, the owner, the car, how many of the four checks are done, and when they applied.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Open an application to decide.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/applications</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/640"><img src="/guides/img/admin-33-applications-desktop-152f9e34.jpg" alt="" loading="lazy" decoding="async" width="1440" height="640"><span class="gd-pin" style="left:36.8%;top:39.7%" aria-hidden="true">1</span><span class="gd-pin" style="left:48.6%;top:53.1%" aria-hidden="true">2</span><span class="gd-pin" style="left:19.8%;top:53.1%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="owners-and-onboarding-decide-on-an-application" data-gd-task><h2 class="gd-h2">Decide on an application</h2><p class="gd-p">One page holds everything: the owner, the car, the uploads, the four checks and the notes.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Check the driver&#39;s licence, the ownership, the insurance and the lender or lessor. Mark each one Checked, fine, Problem or Not needed.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Approve</b>. The step &quot;Terms and first invoice&quot; opens for each car, filled in with the owner&#39;s negotiated terms (or the standard grid): Insurance Fee, Tracker Fee, management fee (Revenue Share), Install Fee and the first and last month amount (2 x the Insurance Fee unless you type an exact amount). Change any of them to the cent.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Choose the invoices: First and last month, Registration fee (any exact amount), Tracker install (only once trackers are available) and Another invoice. For each one choose Send now, Save as draft or Already paid. Already paid asks how (e-Transfer, cash, cheque, bank transfer or other), the date and the reference: it is recorded like Record payment and the owner gets the receipt, not an invoice.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Approve</b> at the bottom of the step. Nothing is set or sent before that. The owner becomes active, the documents open for one signature in their portal, only the invoices you chose are made, and the owner gets one email.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Missing something? Press <b class="gd-ui">Ask for something</b>, tick what you need (for example the ownership permit or the insurance slip), add a message if you like, and press <b class="gd-ui">Send to the owner</b>. The owner gets an email and a task in their portal; the application shows Waiting on owner until they answer.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Not a fit? Press <b class="gd-ui">Decline</b>, write the Reason the owner reads, and press <b class="gd-ui">Decline the application</b>. The owner is emailed for each car.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/applications/166e487a-11a1-4433-b1ca-8c2bc14bf5ca</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/812"><img src="/guides/img/admin-34-application-desktop-98b64f92.jpg" alt="" loading="lazy" decoding="async" width="1440" height="812"><span class="gd-pin" style="left:72.9%;top:67.1%" aria-hidden="true">1</span><span class="gd-pin" style="left:73.9%;top:42.9%" aria-hidden="true">2</span><span class="gd-pin" style="left:84.7%;top:42.9%" aria-hidden="true">3</span><span class="gd-pin" style="left:72.9%;top:49.6%" aria-hidden="true">4</span></div></div></figure></div><p class="gd-p">The application has an Invoices tab: every invoice of its cars, drafts and voids included. An application staff entered for the owner says &quot;Entered by staff&quot; and who; approving it sends the owner the set-up email (review the details and sign) instead of the approval email.</p><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Notes on the page are for staff only: <b class="gd-ui">Add note</b> keeps a line on the record. When the owner answers a request, their answer is in the notes and the application is New again.</div></aside></section><section class="gd-task" id="owners-and-onboarding-add-a-car-for-an-owner" data-gd-task><h2 class="gd-h2">Add a car for an owner</h2><p class="gd-p"><b class="gd-ui">Owners and partners</b> &gt; <b class="gd-ui">Add a car for an owner</b>, or <b class="gd-ui">Add another car</b> on an owner&#39;s page. The owner never has to fill in the application.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The owner: find them by name, email or phone, or choose New owner and enter the name, email, phone and address.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The car: type the VIN. The car is looked up at once and shown in one line (Edit if something is wrong); no VIN at hand, add it by its plate with the year, make and model from the lists. Tap the colour, check the class, then the odometer, insurer and whether it is owned, financed or leased. Photos are optional: the listing shows sample photos until real ones are added. Upload the ownership permit, the insurance slip and the lender&#39;s information if you have them.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Terms and first invoice: the same fields as Approve. For another car of the same owner they start from that owner&#39;s terms.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Who sourced the owner: Entered for CarmaCars, or I sourced this owner (only then are you recorded as the one who brought the owner). How the owner signs: by email, or on paper.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press <b class="gd-ui">Add the car and set it up</b>. The owner gets one email: review the details, correct anything, and sign. An owner with no sign-in gets the link to choose a password in that same email.</div></li></ol></div><p class="gd-p">Customer service and fleet assistants add cars the same way from their portal; theirs wait in Applications for you, with the terms and invoices they proposed already filled in. On an approved application staff entered, <b class="gd-ui">Send the set-up email again</b> sends the owner the email with a fresh link.</p></section><section class="gd-task" id="owners-and-onboarding-owners" data-gd-task><h2 class="gd-h2">Owners</h2><p class="gd-p"><b class="gd-ui">Owners and partners</b> &gt; <b class="gd-ui">Owners</b>. Every owner, with their cars and where onboarding stands.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each owner shows their application, how many cars, and where onboarding stands.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">View as (owner portal)</b> shows their portal. <b class="gd-ui">Send password link</b> helps them sign in.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Invite an owner on file: fill in Name and Email under Invite an owner, then press <b class="gd-ui">Send invitation</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/owners</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/560"><img src="/guides/img/admin-12-owners-desktop-3a54d505.jpg" alt="" loading="lazy" decoding="async" width="1440" height="560"><span class="gd-pin" style="left:41%;top:42.9%" aria-hidden="true">1</span><span class="gd-pin" style="left:37.4%;top:49.3%" aria-hidden="true">2</span><span class="gd-pin" style="left:77.4%;top:82.5%" aria-hidden="true">3</span></div></div></figure></div><p class="gd-p">The owner signs everything at once in their portal (Check and sign: the agreements, schedules, Forms A and B and the official forms that are ready). The confirmations to tick, then one signature: CarmaCars countersigns at the same moment, under the signing officer&#39;s standing authorization. A car with a second owner on the ownership waits for that owner too: they get their own link by email and sign the same documents.</p></section><section class="gd-task" id="owners-and-onboarding-mark-a-car-insured-insurer-confirmed" data-gd-task><h2 class="gd-h2">Mark a car insured (Insurer confirmed)</h2><p class="gd-p">A program owner&#39;s car is handed over to a renter only once the insurer confirms in writing that it is on the fleet policy. Requests, offers and payment never wait for it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each car waiting for the insurer is a line on To do: &quot;Insurer has not confirmed : mark it insured&quot;. It says Now when a booking picks the car up soon.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">When the insurer&#39;s email arrives, press <b class="gd-ui">Mark insured</b>. The date is today; change it to the date of the insurer&#39;s email if it was earlier. Add its subject as the Reference if you like, and press <b class="gd-ui">Insurer confirmed</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">One email for several cars? Press <b class="gd-ui">Mark several insured</b> on the line &quot; cars wait for the insurer&quot;. Every waiting car is ticked: untick any car the insurer did not name, check the date, and confirm them all at once.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The same button is on the car: Overview (<b class="gd-ui">Insurer confirmed</b>) and the Listing tab&#39;s checklist, item &quot;Not on the fleet insurance policy yet&quot;.</div></li></ol></div><p class="gd-p">The car is then on the fleet policy from that date: it can be handed over, its Enrollment Date is that date, its fee terms start, and the owner gets the email &quot;Written confirmation: your car is on the fleet policy&quot;. Its paperwork (agreements, registry visit, tracker) stays on its checklist until done. A car already listed and Available stays Available.</p></section><section class="gd-task" id="owners-and-onboarding-owners-who-paid-another-way-and-the-terms-you-agreed" data-gd-task><h2 class="gd-h2">Owners who paid another way, and the terms you agreed</h2><p class="gd-p">Two lines on To do keep an owner&#39;s money right without opening their page.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">&quot;Record the first and last month paid by &quot;: their first and last month invoice was voided and nothing paid is recorded. Press <b class="gd-ui">Record what they paid</b>, type the amount for each car (tax included), or one total for several cars, how and when it was paid and the reference. A draft first and last month invoice is kept or voided, your choice. Each car&#39;s invoice is then marked paid, the owner gets the receipt and the two prepaid months count. Never for a shareholder.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">&quot;Enter the terms agreed with &quot;: their cars still use the standard grid. Press <b class="gd-ui">Enter the terms</b>: the Management fee (Revenue Share), the Insurance Fee, the Tracker Fee, the Install Fee and the first and last month are filled in from the grid. Type what you agreed for the owner, and open a car to give it its own. A car whose schedule is signed gets an updated schedule for the owner to sign.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Nothing to change? Press <b class="gd-ui">Not needed</b> or <b class="gd-ui">These are correct</b>: the line does not come back.</div></li></ol></div></section><section class="gd-task" id="owners-and-onboarding-a-shareholder-s-own-car" data-gd-task><h2 class="gd-h2">A shareholder&#39;s own car</h2><p class="gd-p">On the owner&#39;s page, each car has <b class="gd-ui">Shareholder’s own car</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A shareholder&#39;s own car is split 90/10 (the share in Program settings) and pays no Insurance Fee, Tracker Fee, first and last month or tracker install.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Shareholder’s own car</b>, say why (it is kept in the audit log) and confirm. Press it again to undo. Bookings already made keep their split.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A first and last month or a tracker install invoice is refused for such a car, from any screen.</div></li></ol></div></section><section class="gd-task" id="owners-and-onboarding-cancellation-refunds" data-gd-task><h2 class="gd-h2">Cancellation refunds</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Program</b>: the refund for each cancellation tier.</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">When the renter cancels</th><th scope="col">Refund (default)</th></tr></thead><tbody><tr><td>Within 24 hours of booking, 48 hours or more before the start</td><td>95%</td></tr><tr><td>48 hours or more before the start</td><td>75%</td></tr><tr><td>24 to 48 hours before the start</td><td>50%</td></tr><tr><td>Under 24 hours, or after the start</td><td>0%</td></tr></tbody></table></div></section><section class="gd-task" id="owners-and-onboarding-an-owner-s-page" data-gd-task><h2 class="gd-h2">An owner&#39;s page</h2><p class="gd-p">Open an owner from Owners. Three tabs: Overview, Terms and Invoices. <b class="gd-ui">Add another car</b> and <b class="gd-ui">New invoice</b> sit under the name.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Upfront invoices: issue the first and last month amount agreed on each car&#39;s terms, for each car whose terms are set.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Owner: address, sign-in, agreements, and what is still missing for the registry forms.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Statements and payouts for this owner.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Forms C and D, with a link to the review queue.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Further down: <b class="gd-ui">View as (owner portal)</b>, <b class="gd-ui">Send password link</b> and <b class="gd-ui">Send a sign-in link to the owner portal</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/owners/9e367055-7780-4451-822a-d79d5b59a309</span></div><div class="gd-imgwrap" style="aspect-ratio:410/1030"><img src="/guides/img/admin-13-owner-desktop-819a9f8b.jpg" alt="" loading="lazy" decoding="async" width="410" height="1030"><span class="gd-pin" style="left:24.6%;top:4.4%" aria-hidden="true">1</span><span class="gd-pin" style="left:16.1%;top:32.9%" aria-hidden="true">2</span><span class="gd-pin" style="left:31.5%;top:73.2%" aria-hidden="true">3</span><span class="gd-pin" style="left:21.2%;top:98.1%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="owners-and-onboarding-an-owner-s-terms" data-gd-task><h2 class="gd-h2">An owner&#39;s terms</h2><p class="gd-p">The Terms tab of an owner&#39;s page: what the owner pays and keeps, exact to the cent.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The owner&#39;s terms are the default for their cars: fill in what you negotiated (leave a field empty to keep the standard grid), the date it applies from, and press <b class="gd-ui">Save the terms</b>. They apply to cars whose terms are set from that date.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each car has its own terms: open Change this car&#39;s terms, type the exact amounts and press <b class="gd-ui">Save the terms</b>. While the Vehicle Schedule is not signed, the schedule changes at once and the documents are made again.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">When the Vehicle Schedule is already signed, saving shows a warning: the owner must sign an updated schedule. Press <b class="gd-ui">Create the updated schedule and email the owner to sign</b>. The current terms stay until the owner signs; then the new ones apply from their date to invoices, debits and statements.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Signed on paper instead? <b class="gd-ui">Record signed on paper</b> with the date. <b class="gd-ui">Withdraw it</b> cancels the update, with a reason.</div></li></ol></div></section><section class="gd-task" id="owners-and-onboarding-paid-and-signed" data-gd-task><h2 class="gd-h2">Paid and signed</h2><p class="gd-p"><b class="gd-ui">Owners and partners</b> &gt; <b class="gd-ui">Paid and signed</b>. What each owner still has to pay or sign, and how each item was done.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each owner shows how many items are open and how many are done. Owners with nothing left are hidden; press Show every owner to see them.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open <b class="gd-ui">Checklist and quick actions</b>. Each line says Signed in the portal, Signed on paper, Paid by e-Transfer, Not signed, and so on.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Paid by e-Transfer, cheque, cash or bank transfer? Press <b class="gd-ui">Record payment</b>. Choose Paid by, the Date received and the Reference (the cheque number for a cheque). Leave Amount empty for the full balance, or type less for a partial payment. Add a photo of the cheque or a screenshot if you have one.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Signed on paper? Press <b class="gd-ui">Record paper signature</b>. Choose the Document, check Signed by and Date signed, add the witnesses where the form needs them, and upload the scan of every signed page.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The same checklist sits at the top of each owner&#39;s page.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">You rarely need to come here: an upfront or overdue owner invoice is a line on To do with <b class="gd-ui">Record payment</b>, and an owner whose documents were sent two days ago or more and are not signed is a line with <b class="gd-ui">Record paper signature</b>. Both pop-ups are the same forms, filled in.</div></li></ol></div><p class="gd-p">A recorded payment marks the invoice paid (or partly paid), stops the automatic debit for that amount, sends the owner a receipt, and shows &quot;Paid by e-Transfer on &quot; in their portal. A paper signature counts as signed everywhere: the checklist, onboarding and the owner portal. The scan is kept privately with the owner&#39;s documents.</p><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>Recorded the wrong thing, or a cheque bounced? Press <b class="gd-ui">Void</b> beside it and give the reason. The invoice owes that amount again and the owner is told; a voided signature makes the item open again. Only an Admin can void.</div></aside></section><section class="gd-task" id="owners-and-onboarding-forms-c-and-d" data-gd-task><h2 class="gd-h2">Forms C and D</h2><p class="gd-p"><b class="gd-ui">Owners and partners</b> &gt; <b class="gd-ui">Owner forms</b>. Form C is signed on screen in the owner portal, with the witness on the same screen. Form D (and Form C on paper, if the owner prefers) is printed, signed in front of witnesses, and sent as a photo of each page.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each row shows the owner, the form, the witnesses and when it was uploaded.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press Open to read the photo or scan. Check each marked spot is signed or initialled.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Approve</b>, or <b class="gd-ui">Send back</b> with What to fix (the owner reads this).</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/owner-forms</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/470"><img src="/guides/img/admin-22-owner-forms-desktop-c20ad300.jpg" alt="" loading="lazy" decoding="async" width="1440" height="470"><span class="gd-pin" style="left:29.2%;top:52.3%" aria-hidden="true">1</span><span class="gd-pin" style="left:57.6%;top:52.3%" aria-hidden="true">2</span><span class="gd-pin" style="left:76.7%;top:52.3%" aria-hidden="true">3</span></div></div></figure></div></section>');
select app.guide_release_section('admin', 'owner-money', 'chapter', 'owners-and-onboarding', 'Owner fee invoices are issued on the notice day and debited on the 15th. Invoices of any amount are made by hand, as drafts first. Statements are built, approved and issued each month, and payouts follow.

## Owner invoices

**Money** > **Owner invoices**. Every owner invoice, drafts and voids included. The same list is on each owner''s and each application''s Invoices tab.

1. Filter by Drafts, Open, Partly paid, Paid, Failed, In arrears or Void, or search by invoice number or owner. Open an invoice to see everything about it.
2. **New invoice** makes an invoice of any amount for an owner''s car, for example a registration fee of $123.45.
3. The monthly run and tracker invoices: **Run the monthly invoices** issues the invoices for the 15th by hand, for a missed month (never twice); **Issue all tracker invoices** bills the Tracker Install for each car waiting for its tracker.

![](/guides/img/admin-14-owner-invoices-desktop-dc4ed1f1.jpg "desktop; size: 1440 1060; address: carmacars.ca/admin/invoices; pins: 1 83.3 22.4, 2 41.7 35.7, 3 29.0 43.4")

## Make, edit and issue an invoice

A new invoice is a draft: the owner sees nothing and it is never debited until you issue it.

1. Choose the car, a title (for example Registration fee) and, if you like, the due date (empty: 7 days after it is issued). Each line: the description, the quantity, the unit amount to the cent, HST on or off, and a note. **Add a line** for more.
2. **Save as draft** to come back to it, or **Save and issue** to send it now. On a draft''s page, **Issue and email** sends it.
3. Paid another way? Press **Record payment** on the invoice. The page lists the payments with their receipts, the automatic debits, the emails sent and the history.
4. **Resend email** sends the invoice again. **PDF** opens it as a PDF.

## Correct an issued invoice

An issued invoice is never edited. You void it and issue a corrected one.

1. Press **Void**, write the reason (the owner reads it), keep Make a corrected invoice from it ticked, and press **Void the invoice**. Its scheduled debit is cancelled and the owner is told.
2. The corrected invoice opens as a draft with the same lines. Fix the amounts and press **Save and issue**.
3. Already paid? Void the payment first, or press **Credit note** for the amount to give back: it gets its own number and the owner sees it.

Invoices issued before October 20, 2026 at the old default (for example $904.00, or $1,017.00 when the Insurance Fee was $450.00) are not changed by themselves. Where an owner agreed another amount, void them and reissue at the agreed amount.

## The automatic debit

The debit runs by itself. Your job is to watch for returned debits and owners without a mandate.

:::flow
Notice day | Invoices issued, one notice per owner, 10 days before
Debit day | The 15th from 6:00: one debit per invoice
Cleared | The invoice is paid
Returned, insufficient funds | The $50.00 Late Fee is added once; the same amount is tried again within 30 days
Returned for another reason | No retry and no Late Fee: the debit pauses and you get a task
:::

1. The tiles show the next debit day and notice day, scheduled, processing, cleared and returned debits.
2. How it runs explains the policy in words, read from Program settings.
3. Scheduled and processing lists each debit. **Pause** holds one (a reason is needed).
4. Owners lists each mandate. Use **Pause**, **Resume** or **Send a notice now**.

![](/guides/img/admin-15-owner-debits-desktop-f65f061a.jpg "desktop; size: 1440 920; address: carmacars.ca/admin/debits; pins: 1 21.8 21.7, 2 21.5 35.5, 3 91.5 75.4, 4 84.7 94.7")

5. Results: each debit, cleared or returned, with the bank''s reason.
6. Run log: each notice and debit run, with its counts.
7. Notices sent: who was told what, for which debit day.

![](/guides/img/admin-15-owner-debits-desktop-8d4682bc.jpg "desktop; size: 1230 520; address: carmacars.ca/admin/debits; pins: 5 11.0 14.4, 6 10.2 52.3, 7 15.4 89.8")

Insufficient funds: the $50.00 Late Fee is added to that invoice once and collected with the owner''s next debit, and the original amount is tried again within 30 days, as section 4.4 of the Enrollment Agreement sets out. The retry is never more than the original amount. Returned again: the invoice is in arrears and you get a task.

> Watch out: Returned for any other reason (account closed, payment stopped, no authorization): there is no retry and no Late Fee. The owner''s debit pauses, the owner gets an email asking them to fix the account or pay another way, and you get a task. A debit is never more than its notice said. An owner with no mandate gets an email on the notice day and you get a task; nothing is debited for them.

## Owner statements

**Money** > **Owner statements**

1. Press **Build all for a month** (or **Build one**).
2. Open each draft. Check it, **Rebuild** after a correction, **Preview PDF**, then **Approve**.
3. Press **Issue to the owner**. **Reissue** sends a corrected copy; **CSV** exports it.

![](/guides/img/admin-16-statements-desktop-43a313ea.jpg "desktop; size: 1440 400; address: carmacars.ca/admin/statements; pins: 1 79.9 27.3")

![An approved statement: the owner gets it by email with the PDF on the 10th, and payouts follow under Payouts.](/guides/img/admin-17-statement-desktop-106ee57f.jpg "desktop; size: 1440 520; address: carmacars.ca/admin/statements/f27936a8-9bfb-4280-81ae-c67ec47febe1; pins: 3 86.0 22.7")

## Staff commissions

**Money** > **Staff commissions**. Nothing is paid automatically.

:::flow
Not earned yet | The rental is ahead, or not paid in full
Pending approval | Completed and paid in full; a Sales month once it has ended
Approved | You approved it; the staff member is told
Paid | You recorded the payment; the staff member is told
Reversed | Cancelled, refunded or charged back; after payment it comes off the next payment
:::

1. By person shows each staff member''s month (Sales: rental days of 100 and the tier), what is not earned yet, pending approval, approved and paid.
2. Press **Approve** on a person (everything that may be approved now) or on one commission.
3. Press **Record a payment**: choose how it was paid (e-Transfer, bank transfer, Wise, cash, the monthly pay statement or another way), the reference and the date.
4. **Prices to review** lists prices typed by hand; **Sourcing claims** lists staff who say they sourced a website request; **Payments made** lists each payment.

|  | Commission |
| --- | --- |
| Sales | By rental days of the month: under 50 days 10%, from 50 days 15%, from 100 days 20%, on all that month''s rentals |
| Customer service, finance, fleet, field staff | 10% (also the field referral fee) |
| Base | The rental charge before tax, after discounts, less refunds |
| On the owner statement | An owner''s car: deducted with the kickbacks before Owner Revenue, its own line on the statement. A partner''s car: from CarmaCars'' commission. A CarmaCars-owned car: a CarmaCars expense |

> Tip: A commission that changes after an owner statement was built (a refund, or the month''s Sales tier) goes on the owner''s next statement as an adjustment line.

## Company statements

CarmaCars'' own monthly statement, in twelve sections.

1. Choose the month. The tiles show revenue, fees, refunds, expenses and the company net.
2. Switch between Total, Per owner and Per vehicle.
3. Download **PDF**, **PDF by owner** or **PDF by vehicle**, or press **Email me the PDFs**.
4. **Finalize** freezes the month. **Rebuild** works until then.

![](/guides/img/admin-18-company-statements-desktop-8e2738ed.jpg "desktop; size: 1440 760; address: carmacars.ca/admin/reports; pins: 1 20.8 28.0, 2 19.4 59.3, 3 77.1 15.5, 4 46.9 15.5")
', 'Owner money', 'Owner invoices (drafts, void and reissue, credit notes), the automatic debit, statements, payouts and the company statement.',
  'Owner fee invoices are issued on the notice day and debited on the 15th. Invoices of any amount are made by hand, as drafts first. Statements are built, approved and issued each month, and payouts follow.

## Owner invoices

**Money** > **Owner invoices**. Every owner invoice, drafts and voids included. The same list is on each owner''s and each application''s Invoices tab.

1. Filter by Drafts, Open, Partly paid, Paid, Failed, In arrears or Void, or search by invoice number or owner. Open an invoice to see everything about it.
2. **New invoice** makes an invoice of any amount for an owner''s car, for example a registration fee of $123.45.
3. The monthly run and tracker invoices: **Run the monthly invoices** issues the invoices for the 15th by hand, for a missed month (never twice); **Issue all tracker invoices** bills the Tracker Install for each car waiting for its tracker.

![](/guides/img/admin-14-owner-invoices-desktop-dc4ed1f1.jpg "desktop; size: 1440 1060; address: carmacars.ca/admin/invoices; pins: 1 83.3 22.4, 2 41.7 35.7, 3 29.0 43.4")

## Make, edit and issue an invoice

A new invoice is a draft: the owner sees nothing and it is never debited until you issue it.

1. Choose the car, a title (for example Registration fee) and, if you like, the due date (empty: 7 days after it is issued). Each line: the description, the quantity, the unit amount to the cent, HST on or off, and a note. **Add a line** for more.
2. **Save as draft** to come back to it, or **Save and issue** to send it now. On a draft''s page, **Issue and email** sends it.
3. Paid another way? Press **Record payment** on the invoice. The page lists the payments with their receipts, the automatic debits, the emails sent and the history.
4. **Resend email** sends the invoice again. **PDF** opens it as a PDF.

## Correct an issued invoice

An issued invoice is never edited. You void it and issue a corrected one.

1. Press **Void**, write the reason (the owner reads it), keep Make a corrected invoice from it ticked, and press **Void the invoice**. Its scheduled debit is cancelled and the owner is told.
2. The corrected invoice opens as a draft with the same lines. Fix the amounts and press **Save and issue**.
3. Already paid? Void the payment first, or press **Credit note** for the amount to give back: it gets its own number and the owner sees it.

Invoices issued before October 20, 2026 at the old default (for example $904.00, or $1,017.00 when the Insurance Fee was $450.00) are not changed by themselves. Where an owner agreed another amount, void them and reissue at the agreed amount.

## The automatic debit

The debit runs by itself. Your job is to watch for returned debits and owners without a mandate.

:::flow
Notice day | Invoices issued, one notice per owner, 10 days before
Debit day | The 15th from 6:00: one debit per invoice
Cleared | The invoice is paid
Returned, insufficient funds | The $50.00 Late Fee is added once; the same amount is tried again within 30 days
Returned for another reason | No retry and no Late Fee: the debit pauses and you get a task
:::

1. The tiles show the next debit day and notice day, scheduled, processing, cleared and returned debits.
2. How it runs explains the policy in words, read from Program settings.
3. Scheduled and processing lists each debit. **Pause** holds one (a reason is needed).
4. Owners lists each mandate. Use **Pause**, **Resume** or **Send a notice now**.

![](/guides/img/admin-15-owner-debits-desktop-f65f061a.jpg "desktop; size: 1440 920; address: carmacars.ca/admin/debits; pins: 1 21.8 21.7, 2 21.5 35.5, 3 91.5 75.4, 4 84.7 94.7")

5. Results: each debit, cleared or returned, with the bank''s reason.
6. Run log: each notice and debit run, with its counts.
7. Notices sent: who was told what, for which debit day.

![](/guides/img/admin-15-owner-debits-desktop-8d4682bc.jpg "desktop; size: 1230 520; address: carmacars.ca/admin/debits; pins: 5 11.0 14.4, 6 10.2 52.3, 7 15.4 89.8")

Insufficient funds: the $50.00 Late Fee is added to that invoice once and collected with the owner''s next debit, and the original amount is tried again within 30 days, as section 4.4 of the Enrollment Agreement sets out. The retry is never more than the original amount. Returned again: the invoice is in arrears and you get a task.

> Watch out: Returned for any other reason (account closed, payment stopped, no authorization): there is no retry and no Late Fee. The owner''s debit pauses, the owner gets an email asking them to fix the account or pay another way, and you get a task. A debit is never more than its notice said. An owner with no mandate gets an email on the notice day and you get a task; nothing is debited for them.

## Owner statements

**Money** > **Owner statements**

1. Press **Build all for a month** (or **Build one**).
2. Open each draft. Check it, **Rebuild** after a correction, **Preview PDF**, then **Approve**.
3. Press **Issue to the owner**. **Reissue** sends a corrected copy; **CSV** exports it.

![](/guides/img/admin-16-statements-desktop-43a313ea.jpg "desktop; size: 1440 400; address: carmacars.ca/admin/statements; pins: 1 79.9 27.3")

![An approved statement: the owner gets it by email with the PDF on the 10th, and payouts follow under Payouts.](/guides/img/admin-17-statement-desktop-106ee57f.jpg "desktop; size: 1440 520; address: carmacars.ca/admin/statements/f27936a8-9bfb-4280-81ae-c67ec47febe1; pins: 3 86.0 22.7")

## Staff commissions

**Money** > **Staff commissions**. Nothing is paid automatically.

:::flow
Not earned yet | The rental is ahead, or not paid in full
Pending approval | Completed and paid in full; a Sales month once it has ended
Approved | You approved it; the staff member is told
Paid | You recorded the payment; the staff member is told
Reversed | Cancelled, refunded or charged back; after payment it comes off the next payment
:::

1. By person shows each staff member''s month (Sales: rental days of 100 and the tier), what is not earned yet, pending approval, approved and paid.
2. Press **Approve** on a person (everything that may be approved now) or on one commission.
3. Press **Record a payment**: choose how it was paid (e-Transfer, bank transfer, Wise, cash, the monthly pay statement or another way), the reference and the date.
4. **Prices to review** lists prices typed by hand; **Sourcing claims** lists staff who say they sourced a website request; **Payments made** lists each payment.

|  | Commission |
| --- | --- |
| Sales | By rental days of the month: under 50 days 10%, from 50 days 15%, from 100 days 20%, on all that month''s rentals |
| Customer service, finance, fleet, field staff | 10% (also the field referral fee) |
| Base | The rental charge before tax, after discounts, with late extra days; never delivery, kilometres, add-ons or anything else bought. Only a refund of the rental charge comes off |
| On the owner statement | An owner''s car: deducted with the kickbacks before Owner Revenue, its own line on the statement. A partner''s car: from CarmaCars'' commission. A CarmaCars-owned car: a CarmaCars expense |

> Tip: A commission that changes after an owner statement was built (a refund, or the month''s Sales tier) goes on the owner''s next statement as an adjustment line.

## Company statements

CarmaCars'' own monthly statement, in twelve sections.

1. Choose the month. The tiles show revenue, fees, refunds, expenses and the company net.
2. Switch between Total, Per owner and Per vehicle.
3. Download **PDF**, **PDF by owner** or **PDF by vehicle**, or press **Email me the PDFs**.
4. **Finalize** freezes the month. **Rebuild** works until then.

![](/guides/img/admin-18-company-statements-desktop-8e2738ed.jpg "desktop; size: 1440 760; address: carmacars.ca/admin/reports; pins: 1 20.8 28.0, 2 19.4 59.3, 3 77.1 15.5, 4 46.9 15.5")
',
  '<p class="gd-p">Owner fee invoices are issued on the notice day and debited on the 15th. Invoices of any amount are made by hand, as drafts first. Statements are built, approved and issued each month, and payouts follow.</p><section class="gd-task" id="owner-money-owner-invoices" data-gd-task><h2 class="gd-h2">Owner invoices</h2><p class="gd-p"><b class="gd-ui">Money</b> &gt; <b class="gd-ui">Owner invoices</b>. Every owner invoice, drafts and voids included. The same list is on each owner&#39;s and each application&#39;s Invoices tab.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Filter by Drafts, Open, Partly paid, Paid, Failed, In arrears or Void, or search by invoice number or owner. Open an invoice to see everything about it.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">New invoice</b> makes an invoice of any amount for an owner&#39;s car, for example a registration fee of $123.45.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The monthly run and tracker invoices: <b class="gd-ui">Run the monthly invoices</b> issues the invoices for the 15th by hand, for a missed month (never twice); <b class="gd-ui">Issue all tracker invoices</b> bills the Tracker Install for each car waiting for its tracker.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/invoices</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1060"><img src="/guides/img/admin-14-owner-invoices-desktop-dc4ed1f1.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1060"><span class="gd-pin" style="left:83.3%;top:22.4%" aria-hidden="true">1</span><span class="gd-pin" style="left:41.7%;top:35.7%" aria-hidden="true">2</span><span class="gd-pin" style="left:29%;top:43.4%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="owner-money-make-edit-and-issue-an-invoice" data-gd-task><h2 class="gd-h2">Make, edit and issue an invoice</h2><p class="gd-p">A new invoice is a draft: the owner sees nothing and it is never debited until you issue it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Choose the car, a title (for example Registration fee) and, if you like, the due date (empty: 7 days after it is issued). Each line: the description, the quantity, the unit amount to the cent, HST on or off, and a note. <b class="gd-ui">Add a line</b> for more.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Save as draft</b> to come back to it, or <b class="gd-ui">Save and issue</b> to send it now. On a draft&#39;s page, <b class="gd-ui">Issue and email</b> sends it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Paid another way? Press <b class="gd-ui">Record payment</b> on the invoice. The page lists the payments with their receipts, the automatic debits, the emails sent and the history.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Resend email</b> sends the invoice again. <b class="gd-ui">PDF</b> opens it as a PDF.</div></li></ol></div></section><section class="gd-task" id="owner-money-correct-an-issued-invoice" data-gd-task><h2 class="gd-h2">Correct an issued invoice</h2><p class="gd-p">An issued invoice is never edited. You void it and issue a corrected one.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Void</b>, write the reason (the owner reads it), keep Make a corrected invoice from it ticked, and press <b class="gd-ui">Void the invoice</b>. Its scheduled debit is cancelled and the owner is told.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The corrected invoice opens as a draft with the same lines. Fix the amounts and press <b class="gd-ui">Save and issue</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Already paid? Void the payment first, or press <b class="gd-ui">Credit note</b> for the amount to give back: it gets its own number and the owner sees it.</div></li></ol></div><p class="gd-p">Invoices issued before October 20, 2026 at the old default (for example $904.00, or $1,017.00 when the Insurance Fee was $450.00) are not changed by themselves. Where an owner agreed another amount, void them and reissue at the agreed amount.</p></section><section class="gd-task" id="owner-money-the-automatic-debit" data-gd-task><h2 class="gd-h2">The automatic debit</h2><p class="gd-p">The debit runs by itself. Your job is to watch for returned debits and owners without a mandate.</p><ol class="gd-flow"><li><b>1</b><span>Notice day</span><em>Invoices issued, one notice per owner, 10 days before</em></li><li><b>2</b><span>Debit day</span><em>The 15th from 6:00: one debit per invoice</em></li><li><b>3</b><span>Cleared</span><em>The invoice is paid</em></li><li><b>4</b><span>Returned, insufficient funds</span><em>The $50.00 Late Fee is added once; the same amount is tried again within 30 days</em></li><li><b>5</b><span>Returned for another reason</span><em>No retry and no Late Fee: the debit pauses and you get a task</em></li></ol><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The tiles show the next debit day and notice day, scheduled, processing, cleared and returned debits.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">How it runs explains the policy in words, read from Program settings.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Scheduled and processing lists each debit. <b class="gd-ui">Pause</b> holds one (a reason is needed).</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Owners lists each mandate. Use <b class="gd-ui">Pause</b>, <b class="gd-ui">Resume</b> or <b class="gd-ui">Send a notice now</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/debits</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/920"><img src="/guides/img/admin-15-owner-debits-desktop-f65f061a.jpg" alt="" loading="lazy" decoding="async" width="1440" height="920"><span class="gd-pin" style="left:21.8%;top:21.7%" aria-hidden="true">1</span><span class="gd-pin" style="left:21.5%;top:35.5%" aria-hidden="true">2</span><span class="gd-pin" style="left:91.5%;top:75.4%" aria-hidden="true">3</span><span class="gd-pin" style="left:84.7%;top:94.7%" aria-hidden="true">4</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="5"><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Results: each debit, cleared or returned, with the bank&#39;s reason.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Run log: each notice and debit run, with its counts.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Notices sent: who was told what, for which debit day.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/debits</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/520"><img src="/guides/img/admin-15-owner-debits-desktop-8d4682bc.jpg" alt="" loading="lazy" decoding="async" width="1230" height="520"><span class="gd-pin" style="left:11%;top:14.4%" aria-hidden="true">5</span><span class="gd-pin" style="left:10.2%;top:52.3%" aria-hidden="true">6</span><span class="gd-pin" style="left:15.4%;top:89.8%" aria-hidden="true">7</span></div></div></figure></div><p class="gd-p">Insufficient funds: the $50.00 Late Fee is added to that invoice once and collected with the owner&#39;s next debit, and the original amount is tried again within 30 days, as section 4.4 of the Enrollment Agreement sets out. The retry is never more than the original amount. Returned again: the invoice is in arrears and you get a task.</p><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>Returned for any other reason (account closed, payment stopped, no authorization): there is no retry and no Late Fee. The owner&#39;s debit pauses, the owner gets an email asking them to fix the account or pay another way, and you get a task. A debit is never more than its notice said. An owner with no mandate gets an email on the notice day and you get a task; nothing is debited for them.</div></aside></section><section class="gd-task" id="owner-money-owner-statements" data-gd-task><h2 class="gd-h2">Owner statements</h2><p class="gd-p"><b class="gd-ui">Money</b> &gt; <b class="gd-ui">Owner statements</b></p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Build all for a month</b> (or <b class="gd-ui">Build one</b>).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open each draft. Check it, <b class="gd-ui">Rebuild</b> after a correction, <b class="gd-ui">Preview PDF</b>, then <b class="gd-ui">Approve</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Issue to the owner</b>. <b class="gd-ui">Reissue</b> sends a corrected copy; <b class="gd-ui">CSV</b> exports it.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/statements</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/400"><img src="/guides/img/admin-16-statements-desktop-43a313ea.jpg" alt="" loading="lazy" decoding="async" width="1440" height="400"><span class="gd-pin" style="left:79.9%;top:27.3%" aria-hidden="true">1</span></div></div></figure></div><div class="gd-figblock"><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/statements/f27936a8-9bfb-4280-81ae-c67ec47febe1</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/520"><img src="/guides/img/admin-17-statement-desktop-106ee57f.jpg" alt="An approved statement: the owner gets it by email with the PDF on the 10th, and payouts follow under Payouts." loading="lazy" decoding="async" width="1440" height="520"><span class="gd-pin" style="left:86%;top:22.7%" aria-hidden="true">3</span></div></div><figcaption>An approved statement: the owner gets it by email with the PDF on the 10th, and payouts follow under Payouts.</figcaption></figure></div></section><section class="gd-task" id="owner-money-staff-commissions" data-gd-task><h2 class="gd-h2">Staff commissions</h2><p class="gd-p"><b class="gd-ui">Money</b> &gt; <b class="gd-ui">Staff commissions</b>. Nothing is paid automatically.</p><ol class="gd-flow"><li><b>1</b><span>Not earned yet</span><em>The rental is ahead, or not paid in full</em></li><li><b>2</b><span>Pending approval</span><em>Completed and paid in full; a Sales month once it has ended</em></li><li><b>3</b><span>Approved</span><em>You approved it; the staff member is told</em></li><li><b>4</b><span>Paid</span><em>You recorded the payment; the staff member is told</em></li><li><b>5</b><span>Reversed</span><em>Cancelled, refunded or charged back; after payment it comes off the next payment</em></li></ol><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">By person shows each staff member&#39;s month (Sales: rental days of 100 and the tier), what is not earned yet, pending approval, approved and paid.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Approve</b> on a person (everything that may be approved now) or on one commission.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Record a payment</b>: choose how it was paid (e-Transfer, bank transfer, Wise, cash, the monthly pay statement or another way), the reference and the date.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Prices to review</b> lists prices typed by hand; <b class="gd-ui">Sourcing claims</b> lists staff who say they sourced a website request; <b class="gd-ui">Payments made</b> lists each payment.</div></li></ol></div><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col"></th><th scope="col">Commission</th></tr></thead><tbody><tr><td>Sales</td><td>By rental days of the month: under 50 days 10%, from 50 days 15%, from 100 days 20%, on all that month&#39;s rentals</td></tr><tr><td>Customer service, finance, fleet, field staff</td><td>10% (also the field referral fee)</td></tr><tr><td>Base</td><td>The rental charge before tax, after discounts, with late extra days; never delivery, kilometres, add-ons or anything else bought. Only a refund of the rental charge comes off</td></tr><tr><td>On the owner statement</td><td>An owner&#39;s car: deducted with the kickbacks before Owner Revenue, its own line on the statement. A partner&#39;s car: from CarmaCars&#39; commission. A CarmaCars-owned car: a CarmaCars expense</td></tr></tbody></table></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A commission that changes after an owner statement was built (a refund, or the month&#39;s Sales tier) goes on the owner&#39;s next statement as an adjustment line.</div></aside></section><section class="gd-task" id="owner-money-company-statements" data-gd-task><h2 class="gd-h2">Company statements</h2><p class="gd-p">CarmaCars&#39; own monthly statement, in twelve sections.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Choose the month. The tiles show revenue, fees, refunds, expenses and the company net.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Switch between Total, Per owner and Per vehicle.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Download <b class="gd-ui">PDF</b>, <b class="gd-ui">PDF by owner</b> or <b class="gd-ui">PDF by vehicle</b>, or press <b class="gd-ui">Email me the PDFs</b>.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Finalize</b> freezes the month. <b class="gd-ui">Rebuild</b> works until then.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/reports</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/760"><img src="/guides/img/admin-18-company-statements-desktop-8e2738ed.jpg" alt="" loading="lazy" decoding="async" width="1440" height="760"><span class="gd-pin" style="left:20.8%;top:28%" aria-hidden="true">1</span><span class="gd-pin" style="left:19.4%;top:59.3%" aria-hidden="true">2</span><span class="gd-pin" style="left:77.1%;top:15.5%" aria-hidden="true">3</span><span class="gd-pin" style="left:46.9%;top:15.5%" aria-hidden="true">4</span></div></div></figure></div></section>');
select app.guide_release_section('admin', 'live-visitors-and-live-chat', 'chapter', 'tolls-and-tickets', 'See who is on the site right now and what they look at, with buying signals, and answer the live chat. The CarmaCars assistant answers the chat first; you take over whenever you want, and it hands over by itself for complaints, damage, payments and anything it should not answer.

## Live visitors

Visitors who accepted analytics, known customers on their own booking pages and anyone in a chat.

1. Open **Today** > **Live visitors**. The tiles count who is on the site now, known customers, visits and chats today.
2. Each visitor shows their name when known (signed in, or arrived from one of our emails), otherwise "Visitor from Toronto, phone"; the page and car they are on; the pages and cars of this visit; their visit number, device, city and the site or campaign that sent them.
3. Badges are buying signals: "Viewing spree: 6 cars in 10 minutes", "Opened offer CC-1042, not answered", "Opened the change proposal twice", "Left the pay page", "Returning visitor, 3rd visit this week", "Started a request and stopped".
4. Press **Pages** for every page and event of the visit, or **Start a chat** to write to the visitor. They see your message in a bubble and reply from it.
5. Below: the signals of the last 24 hours and the most viewed cars of the week. The page refreshes by itself every few seconds.

## Follow-up tasks

Signals of known visitors become tasks with a suggested action, for example "Call or message Maya Chen: opened offer CC-1042 twice, no answer for 6 hours".

- An offer opened and not answered: after 6 hours, to Sales when the booking is credited to someone in Sales, otherwise customer service.
- The pay page left without paying: after 30 minutes, customer service. The change proposal opened twice: customer service.
- A booking request started and stopped, or a viewing spree, by a known visitor: Sales.
- A task closes by itself when the renter answers the offer, pays or answers the proposal. Each signal raises one task only.
- The thresholds are in **Settings** > **Program**, group "Live visitors and live chat". Follow-ups done count in My sales.

## Recovery emails

Known renters who stop before finishing get one polite reminder, and at most one more a day later.

- An offer opened and not answered: after 4 hours. The pay page left without paying: after an hour. A change proposal opened and not answered: after 4 hours.
- A booking request started and not sent: after 2 hours, and only to renters who agreed to hear from us (marketing consent).
- Sent only between 9:00 and 21:00 Toronto time, never to someone who unsubscribed, and never while a staff member is handling the renter (a task they took, a chat with a person, a message from staff).
- They stop as soon as the renter answers, pays or sends the request; a reminder still waiting is not sent. The delays and hours are in Program settings, "Booking recovery emails".

## Interest in a car

**Cars** > **Vehicles**, a car, Overview: "Interest on the site" shows who is looking now, views today and in 7 days, conversion over 30 days (requests from the people who viewed it) and the last 14 days. The Vehicles list has "Most viewed cars this week".

## A renter''s visits

On a renter''s page (People > Renters, the name) and on a booking''s History tab, "On the site" lists when they viewed the offer, opened the change proposal, viewed or left the pay page, which cars they looked at, and their chats.

## Live chat

1. Open **Bookings** > **Live chat**. The menu counts chats waiting for a person. Open chats come first, those waiting for a person on top, with their minutes against the first reply target (5 minutes).
2. Choose a conversation. Beside it you see the visitor''s page, pages, signals, and the renter with their bookings when known.
3. Press **Take over**: the assistant stops and the visitor reads that you joined. Writing a reply also takes over. Press **Send** (or Enter).
4. **Hand back to the assistant** lets it answer again. **Close** ends the chat; if the visitor gave an email they get a copy. **Email the transcript** sends it any time.
5. Notify me: "Email me when a chat waits (while I am on shift)" and desktop alerts in this browser. You are on shift while Live chat or Live visitors is open.

> Tip: The assistant only repeats prices from our pricing (a quote or the car''s rates), never offers discounts or promises a car, never talks about insurance and never names a provider. Each reply it was not allowed to send says so in the conversation. When nobody is on shift, the chat asks for the visitor''s name, email or phone and raises a task. A booking from a chat you handled is credited only when you choose "I sourced this client" on the quote or offer.

## The assistant''s settings

In Program settings, "Live visitors and live chat": the chat on or off, the AI first or not, its model, the neurons it may use a day (6,000, about 10 chats; then chats wait for a person), the greeting on car pages after some seconds (off by default), how long chats and visits are kept (12 months and 90 days, as the privacy policy says).
', 'Live visitors and live chat', 'Who is on the site now, how likely each visitor is to book and why, one-click actions, follow-ups, interest per car, the chat inbox.',
  'See who is on the site right now and what they look at, with buying signals, and answer the live chat. The CarmaCars assistant answers the chat first; you take over whenever you want, and it hands over by itself for complaints, damage, payments and anything it should not answer.

## Live visitors

Visitors who accepted analytics (or got the notice in Canada outside Quebec and the US), known customers on their own booking pages and anyone in a chat.

1. Open **Today** > **Live visitors**. The tiles count who is on the site now, hot visitors now, known customers, visits and chats today. The menu shows how many hot visitors are on the site.
2. Each visitor shows a booking likelihood from 0 to 100, with Hot (60 or more), Warm (30 or more) or Cold. The list is sorted by it; choose "Most recent" in Sort, or tick "Hot and warm only".
3. "Why" gives the three strongest reasons, for example "Pickup tomorrow · Reached step 3 of the request form · Tapped to call". The badges are all the signals of the visit; the dots say how strong each is.
4. Each visitor also shows their name when known (signed in, or arrived from one of our emails), otherwise "Visitor from Toronto, phone"; the page and car they are on, and how many others look at that car now; the device, city, the site or campaign that sent them and "from an ad".
5. Suggested: the best next step and the message to send. Press **Invite to chat with this message** to send it at once, **Edit the message** to change it first, **Offer a 10% discount code**, **Assign to Sales** or, when their dates are taken, **Suggest a similar free car**.
6. Press **Pages** for every page and event of the visit with each signal''s points, or **Start a chat** to write your own message. They see it in a bubble and reply from it.
7. Below: hot visitors today (and whether someone acted), the signals of the last 24 hours, and the most viewed cars of the week with prices shown and the car most compared with each. The page refreshes by itself every few seconds.

## The signals

Each signal adds points to the booking likelihood. They come from what the visitor does on the site, never from what they type.

- Intent: dates searched again and again, saw the full price, reached the booking form (and which step), came back for the same car on another day, comparing two or three cars, read the cancellation policy, read about the deposit, insurance or requirements, tapped to call, text or WhatsApp us or copied our number, checked delivery, looked through many photos or stayed long on one car.
- Urgency: pickup within 72 hours, weekend or holiday dates, on a phone late at night, came from a city or model page or a "near me" search.
- Value: a weekly or monthly rental, a premium car, SUV or van, adding a driver, asked about young drivers, a business email.
- Hesitation: watching the price (sorted by lowest price, lowered the price limit), left after seeing the price, unsure about the deposit, trouble with a form, the car not free for their dates.
- Context: came from an ad, a past renter, an offer or payment waiting, a game code not used yet, a popular car. The signals of known customers (offer opened, pay page left, change proposal, request stopped, returning visitor, viewing spree) count too.

## Hot visitors and the actions

- When a visitor turns hot, everyone with Live visitors open sees an alert at the top of the page. Turn on desktop alerts in Live chat to get one on your computer too; none come in the quiet hours (11 pm to 7 am). No email is sent.
- A discount code is single use, 10% off the rental charge (at most $75), valid 3 days, one per visitor a week and 10 a day per person. Admins and Sales send them; the code goes in the chat with the message.
- Assign to Sales gives the visitor to the Sales person on shift (or to you if you work Sales) and raises a task with the reasons and the contact when we know who they are.
- Each action shows on the visitor ("Invited by Lena, 2 min ago") so two people do not write to the same visitor.

## Signal settings

1. Open **Today** > **Live visitors** and press **Signal settings**.
2. Score and actions: from how many points a visitor is hot or warm, when a signal is strong or medium, the hot alert, and the discount code (percent, most off a booking, days valid, codes a day per person, whether customer service may send codes, and the message).
3. Each signal: on or off, its points, its thresholds (for example 72 hours for "Pickup soon", 3 searches for "Searching dates again and again"), the suggested action and the message. {car}, {days}, {pickup} and the other words in braces are filled in from the visit.
4. Press **Save the signals**. The next look at each visit uses them.

## Follow-up tasks

Signals of known visitors become tasks with a suggested action, for example "Call or message Maya Chen: opened offer CC-1042 twice, no answer for 6 hours".

- An offer opened and not answered: after 6 hours, to Sales when the booking is credited to someone in Sales, otherwise customer service.
- The pay page left without paying: after 30 minutes, customer service. The change proposal opened twice: customer service.
- A booking request started and stopped, or a viewing spree, by a known visitor: Sales.
- A task closes by itself when the renter answers the offer, pays or answers the proposal. Each signal raises one task only.
- The thresholds are in **Settings** > **Program**, group "Live visitors and live chat". Follow-ups done count in My sales.

## Recovery emails

Known renters who stop before finishing get one polite reminder, and at most one more a day later.

- An offer opened and not answered: after 4 hours. The pay page left without paying: after an hour. A change proposal opened and not answered: after 4 hours.
- A booking request started and not sent: after 2 hours, and only to renters who agreed to hear from us (marketing consent).
- Sent only between 9:00 and 21:00 Toronto time, never to someone who unsubscribed, and never while a staff member is handling the renter (a task they took, a chat with a person, a message from staff).
- They stop as soon as the renter answers, pays or sends the request; a reminder still waiting is not sent. The delays and hours are in Program settings, "Booking recovery emails".

## Interest in a car

**Cars** > **Vehicles**, a car, Overview: "Interest on the site" shows who is looking now, views today and in 7 days, the people who saw the price for their dates, conversion over 30 days (requests from the people who viewed it), the cars most often compared with it, and the last 14 days. The Vehicles list has "Most viewed cars this week".

## A renter''s visits

On a renter''s page (People > Renters, the name) and on a booking''s History tab, "On the site" lists when they viewed the offer, opened the change proposal, viewed or left the pay page, which cars they looked at, and their chats.

## Live chat

1. A visitor who asks for a person is a line on To do, marked Now: press **Open the chat**. Or open **Bookings** > **Live chat**. The menu counts chats waiting for a person. Open chats come first, those waiting for a person on top, with their minutes against the first reply target (5 minutes).
2. Choose a conversation. Beside it you see the visitor''s page, pages, signals, and the renter with their bookings when known.
3. Press **Take over**: the assistant stops and the visitor reads that you joined. Writing a reply also takes over. Press **Send** (or Enter).
4. **Hand back to the assistant** lets it answer again. **Close** ends the chat; if the visitor gave an email they get a copy. **Email the transcript** sends it any time.
5. Notify me: "Email me when a chat waits (while I am on shift)" and desktop alerts in this browser. You are on shift while Live chat or Live visitors is open.

> Tip: The assistant only repeats prices from our pricing (a quote or the car''s rates), never offers discounts or promises a car, never talks about insurance and never names a provider. Each reply it was not allowed to send says so in the conversation. When nobody is on shift, the chat asks for the visitor''s name, email or phone and raises a task. A booking from a chat you handled is credited only when you choose "I sourced this client" on the quote or offer.

## The assistant''s settings

In Program settings, "Live visitors and live chat": the chat on or off, the AI first or not, its model, the neurons it may use a day (6,000, about 10 chats; then chats wait for a person), the greeting on car pages after some seconds (off by default), how long chats and visits are kept (12 months and 90 days, as the privacy policy says).
',
  '<p class="gd-p">See who is on the site right now and what they look at, with buying signals, and answer the live chat. The CarmaCars assistant answers the chat first; you take over whenever you want, and it hands over by itself for complaints, damage, payments and anything it should not answer.</p><section class="gd-task" id="live-visitors-and-live-chat-live-visitors" data-gd-task><h2 class="gd-h2">Live visitors</h2><p class="gd-p">Visitors who accepted analytics (or got the notice in Canada outside Quebec and the US), known customers on their own booking pages and anyone in a chat.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Today</b> &gt; <b class="gd-ui">Live visitors</b>. The tiles count who is on the site now, hot visitors now, known customers, visits and chats today. The menu shows how many hot visitors are on the site.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each visitor shows a booking likelihood from 0 to 100, with Hot (60 or more), Warm (30 or more) or Cold. The list is sorted by it; choose &quot;Most recent&quot; in Sort, or tick &quot;Hot and warm only&quot;.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">&quot;Why&quot; gives the three strongest reasons, for example &quot;Pickup tomorrow · Reached step 3 of the request form · Tapped to call&quot;. The badges are all the signals of the visit; the dots say how strong each is.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Each visitor also shows their name when known (signed in, or arrived from one of our emails), otherwise &quot;Visitor from Toronto, phone&quot;; the page and car they are on, and how many others look at that car now; the device, city, the site or campaign that sent them and &quot;from an ad&quot;.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Suggested: the best next step and the message to send. Press <b class="gd-ui">Invite to chat with this message</b> to send it at once, <b class="gd-ui">Edit the message</b> to change it first, <b class="gd-ui">Offer a 10% discount code</b>, <b class="gd-ui">Assign to Sales</b> or, when their dates are taken, <b class="gd-ui">Suggest a similar free car</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Press <b class="gd-ui">Pages</b> for every page and event of the visit with each signal&#39;s points, or <b class="gd-ui">Start a chat</b> to write your own message. They see it in a bubble and reply from it.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Below: hot visitors today (and whether someone acted), the signals of the last 24 hours, and the most viewed cars of the week with prices shown and the car most compared with each. The page refreshes by itself every few seconds.</div></li></ol></div></section><section class="gd-task" id="live-visitors-and-live-chat-the-signals" data-gd-task><h2 class="gd-h2">The signals</h2><p class="gd-p">Each signal adds points to the booking likelihood. They come from what the visitor does on the site, never from what they type.</p><ul class="gd-ul"><li>Intent: dates searched again and again, saw the full price, reached the booking form (and which step), came back for the same car on another day, comparing two or three cars, read the cancellation policy, read about the deposit, insurance or requirements, tapped to call, text or WhatsApp us or copied our number, checked delivery, looked through many photos or stayed long on one car.</li><li>Urgency: pickup within 72 hours, weekend or holiday dates, on a phone late at night, came from a city or model page or a &quot;near me&quot; search.</li><li>Value: a weekly or monthly rental, a premium car, SUV or van, adding a driver, asked about young drivers, a business email.</li><li>Hesitation: watching the price (sorted by lowest price, lowered the price limit), left after seeing the price, unsure about the deposit, trouble with a form, the car not free for their dates.</li><li>Context: came from an ad, a past renter, an offer or payment waiting, a game code not used yet, a popular car. The signals of known customers (offer opened, pay page left, change proposal, request stopped, returning visitor, viewing spree) count too.</li></ul></section><section class="gd-task" id="live-visitors-and-live-chat-hot-visitors-and-the-actions" data-gd-task><h2 class="gd-h2">Hot visitors and the actions</h2><ul class="gd-ul"><li>When a visitor turns hot, everyone with Live visitors open sees an alert at the top of the page. Turn on desktop alerts in Live chat to get one on your computer too; none come in the quiet hours (11 pm to 7 am). No email is sent.</li><li>A discount code is single use, 10% off the rental charge (at most $75), valid 3 days, one per visitor a week and 10 a day per person. Admins and Sales send them; the code goes in the chat with the message.</li><li>Assign to Sales gives the visitor to the Sales person on shift (or to you if you work Sales) and raises a task with the reasons and the contact when we know who they are.</li><li>Each action shows on the visitor (&quot;Invited by Lena, 2 min ago&quot;) so two people do not write to the same visitor.</li></ul></section><section class="gd-task" id="live-visitors-and-live-chat-signal-settings" data-gd-task><h2 class="gd-h2">Signal settings</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Today</b> &gt; <b class="gd-ui">Live visitors</b> and press <b class="gd-ui">Signal settings</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Score and actions: from how many points a visitor is hot or warm, when a signal is strong or medium, the hot alert, and the discount code (percent, most off a booking, days valid, codes a day per person, whether customer service may send codes, and the message).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Each signal: on or off, its points, its thresholds (for example 72 hours for &quot;Pickup soon&quot;, 3 searches for &quot;Searching dates again and again&quot;), the suggested action and the message. {car}, {days}, {pickup} and the other words in braces are filled in from the visit.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Save the signals</b>. The next look at each visit uses them.</div></li></ol></div></section><section class="gd-task" id="live-visitors-and-live-chat-follow-up-tasks" data-gd-task><h2 class="gd-h2">Follow-up tasks</h2><p class="gd-p">Signals of known visitors become tasks with a suggested action, for example &quot;Call or message Maya Chen: opened offer CC-1042 twice, no answer for 6 hours&quot;.</p><ul class="gd-ul"><li>An offer opened and not answered: after 6 hours, to Sales when the booking is credited to someone in Sales, otherwise customer service.</li><li>The pay page left without paying: after 30 minutes, customer service. The change proposal opened twice: customer service.</li><li>A booking request started and stopped, or a viewing spree, by a known visitor: Sales.</li><li>A task closes by itself when the renter answers the offer, pays or answers the proposal. Each signal raises one task only.</li><li>The thresholds are in <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Program</b>, group &quot;Live visitors and live chat&quot;. Follow-ups done count in My sales.</li></ul></section><section class="gd-task" id="live-visitors-and-live-chat-recovery-emails" data-gd-task><h2 class="gd-h2">Recovery emails</h2><p class="gd-p">Known renters who stop before finishing get one polite reminder, and at most one more a day later.</p><ul class="gd-ul"><li>An offer opened and not answered: after 4 hours. The pay page left without paying: after an hour. A change proposal opened and not answered: after 4 hours.</li><li>A booking request started and not sent: after 2 hours, and only to renters who agreed to hear from us (marketing consent).</li><li>Sent only between 9:00 and 21:00 Toronto time, never to someone who unsubscribed, and never while a staff member is handling the renter (a task they took, a chat with a person, a message from staff).</li><li>They stop as soon as the renter answers, pays or sends the request; a reminder still waiting is not sent. The delays and hours are in Program settings, &quot;Booking recovery emails&quot;.</li></ul></section><section class="gd-task" id="live-visitors-and-live-chat-interest-in-a-car" data-gd-task><h2 class="gd-h2">Interest in a car</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Vehicles</b>, a car, Overview: &quot;Interest on the site&quot; shows who is looking now, views today and in 7 days, the people who saw the price for their dates, conversion over 30 days (requests from the people who viewed it), the cars most often compared with it, and the last 14 days. The Vehicles list has &quot;Most viewed cars this week&quot;.</p></section><section class="gd-task" id="live-visitors-and-live-chat-a-renter-s-visits" data-gd-task><h2 class="gd-h2">A renter&#39;s visits</h2><p class="gd-p">On a renter&#39;s page (People &gt; Renters, the name) and on a booking&#39;s History tab, &quot;On the site&quot; lists when they viewed the offer, opened the change proposal, viewed or left the pay page, which cars they looked at, and their chats.</p></section><section class="gd-task" id="live-visitors-and-live-chat-live-chat" data-gd-task><h2 class="gd-h2">Live chat</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A visitor who asks for a person is a line on To do, marked Now: press <b class="gd-ui">Open the chat</b>. Or open <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Live chat</b>. The menu counts chats waiting for a person. Open chats come first, those waiting for a person on top, with their minutes against the first reply target (5 minutes).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose a conversation. Beside it you see the visitor&#39;s page, pages, signals, and the renter with their bookings when known.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Take over</b>: the assistant stops and the visitor reads that you joined. Writing a reply also takes over. Press <b class="gd-ui">Send</b> (or Enter).</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Hand back to the assistant</b> lets it answer again. <b class="gd-ui">Close</b> ends the chat; if the visitor gave an email they get a copy. <b class="gd-ui">Email the transcript</b> sends it any time.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Notify me: &quot;Email me when a chat waits (while I am on shift)&quot; and desktop alerts in this browser. You are on shift while Live chat or Live visitors is open.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The assistant only repeats prices from our pricing (a quote or the car&#39;s rates), never offers discounts or promises a car, never talks about insurance and never names a provider. Each reply it was not allowed to send says so in the conversation. When nobody is on shift, the chat asks for the visitor&#39;s name, email or phone and raises a task. A booking from a chat you handled is credited only when you choose &quot;I sourced this client&quot; on the quote or offer.</div></aside></section><section class="gd-task" id="live-visitors-and-live-chat-the-assistant-s-settings" data-gd-task><h2 class="gd-h2">The assistant&#39;s settings</h2><p class="gd-p">In Program settings, &quot;Live visitors and live chat&quot;: the chat on or off, the AI first or not, its model, the neurons it may use a day (6,000, about 10 chats; then chats wait for a person), the greeting on car pages after some seconds (off by default), how long chats and visits are kept (12 months and 90 days, as the privacy policy says).</p></section>');
select app.guide_release_section('admin', 'texts-and-calls-the-quo-phone-line', 'chapter', 'live-visitors-and-live-chat', null, 'Texts and calls (the Quo phone line)', 'Texts and calls in the chat inbox, unknown callers, missed calls, booking texts, call summaries and the settings.',
  'Every call and text on the CarmaCars number (Quo) is kept and matched to the person: staff, a renter and their booking, an owner or a lead. Staff answer texts from the same inbox as live chat. It is on by default; Program settings switch each part.

## The inbox

1. Open **Bookings** > **Live chat** and press **Texts and calls**. Each number shows who it is (Renter, Owner, Lead, Staff or Unknown caller), unread texts and missed calls.
2. Choose a number. Calls and texts are in order; a call shows its length, and Quo''s summary or a one-line AI summary when there is one.
3. Write a text and press **Send text**: it goes from the CarmaCars number through Quo. **Suggest a reply** puts an AI draft in the box; nothing is ever sent until you press Send text.
4. Beside the conversation: the renter with their bookings, the owner or the lead. A caller who gave the same phone in live chat or a discount game shows their visit on the site.
5. **Stop texts** stops every text to the number, booking texts included. A person who texts STOP is stopped the same way; START allows texts again.

## Unknown callers

Press **Unknown callers**. For a number nobody on file has, type the name if you know it and press **Create lead**, or find the renter and press **Link to** the name. The calls and texts so far follow the link. **Match automatically again** undoes a link made by hand.

## Missed calls

A missed call raises the task "Missed call from ..." for the person on duty in customer service (whoever has Live chat or Texts and calls open), otherwise the customer service queue, and the Admins when nobody holds that function. In the quiet hours (11 pm to 7 am) the task is due at 7 am. One open task per number.

> Tip: Quo itself texts back missed callers (its own auto-reply). The platform can do it instead (Program settings, "Missed call: text the caller back"), once per number in 12 hours: turn off Quo''s own auto-reply first, or callers get two texts.

## Calls and texts on records

A booking''s History tab, a renter''s page and an owner''s page have "Calls and texts": the texts, calls, missed calls, voicemails and summaries with that person. Calls are not recorded on the line for now, so there is no transcript or recording to show.

## Booking texts

Renters with a mobile number get a short text beside some emails: the offer, the booking confirmed, a payment received, the pickup tomorrow, the return reminder and the payment link after they left the pay page. The first one ends "Reply STOP to opt out." They are about the booking only, never marketing, and wait for the end of the quiet hours.

## The settings

Program settings, "Phone and texts (Quo)": the line on or off, calls and texts kept, the missed-call text and its task, who calls back, AI suggestions and summaries with their daily neurons, the visit of a caller, each booking text on or off with its wording ({first_name}, {booking}, {car}, {pickup}, {return}, {amount}, {link}; short, no long dashes, naming CarmaCars), and how long calls and texts of people who are not customers are kept (12 months).
',
  '<p class="gd-p">Every call and text on the CarmaCars number (Quo) is kept and matched to the person: staff, a renter and their booking, an owner or a lead. Staff answer texts from the same inbox as live chat. It is on by default; Program settings switch each part.</p><section class="gd-task" id="texts-and-calls-the-quo-phone-line-the-inbox" data-gd-task><h2 class="gd-h2">The inbox</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Live chat</b> and press <b class="gd-ui">Texts and calls</b>. Each number shows who it is (Renter, Owner, Lead, Staff or Unknown caller), unread texts and missed calls.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose a number. Calls and texts are in order; a call shows its length, and Quo&#39;s summary or a one-line AI summary when there is one.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Write a text and press <b class="gd-ui">Send text</b>: it goes from the CarmaCars number through Quo. <b class="gd-ui">Suggest a reply</b> puts an AI draft in the box; nothing is ever sent until you press Send text.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Beside the conversation: the renter with their bookings, the owner or the lead. A caller who gave the same phone in live chat or a discount game shows their visit on the site.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><b class="gd-ui">Stop texts</b> stops every text to the number, booking texts included. A person who texts STOP is stopped the same way; START allows texts again.</div></li></ol></div></section><section class="gd-task" id="texts-and-calls-the-quo-phone-line-unknown-callers" data-gd-task><h2 class="gd-h2">Unknown callers</h2><p class="gd-p">Press <b class="gd-ui">Unknown callers</b>. For a number nobody on file has, type the name if you know it and press <b class="gd-ui">Create lead</b>, or find the renter and press <b class="gd-ui">Link to</b> the name. The calls and texts so far follow the link. <b class="gd-ui">Match automatically again</b> undoes a link made by hand.</p></section><section class="gd-task" id="texts-and-calls-the-quo-phone-line-missed-calls" data-gd-task><h2 class="gd-h2">Missed calls</h2><p class="gd-p">A missed call raises the task &quot;Missed call from ...&quot; for the person on duty in customer service (whoever has Live chat or Texts and calls open), otherwise the customer service queue, and the Admins when nobody holds that function. In the quiet hours (11 pm to 7 am) the task is due at 7 am. One open task per number.</p><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Quo itself texts back missed callers (its own auto-reply). The platform can do it instead (Program settings, &quot;Missed call: text the caller back&quot;), once per number in 12 hours: turn off Quo&#39;s own auto-reply first, or callers get two texts.</div></aside></section><section class="gd-task" id="texts-and-calls-the-quo-phone-line-calls-and-texts-on-records" data-gd-task><h2 class="gd-h2">Calls and texts on records</h2><p class="gd-p">A booking&#39;s History tab, a renter&#39;s page and an owner&#39;s page have &quot;Calls and texts&quot;: the texts, calls, missed calls, voicemails and summaries with that person. Calls are not recorded on the line for now, so there is no transcript or recording to show.</p></section><section class="gd-task" id="texts-and-calls-the-quo-phone-line-booking-texts" data-gd-task><h2 class="gd-h2">Booking texts</h2><p class="gd-p">Renters with a mobile number get a short text beside some emails: the offer, the booking confirmed, a payment received, the pickup tomorrow, the return reminder and the payment link after they left the pay page. The first one ends &quot;Reply STOP to opt out.&quot; They are about the booking only, never marketing, and wait for the end of the quiet hours.</p></section><section class="gd-task" id="texts-and-calls-the-quo-phone-line-the-settings" data-gd-task><h2 class="gd-h2">The settings</h2><p class="gd-p">Program settings, &quot;Phone and texts (Quo)&quot;: the line on or off, calls and texts kept, the missed-call text and its task, who calls back, AI suggestions and summaries with their daily neurons, the visit of a caller, each booking text on or off with its wording ({first_name}, {booking}, {car}, {pickup}, {return}, {amount}, {link}; short, no long dashes, naming CarmaCars), and how long calls and texts of people who are not customers are kept (12 months).</p></section>');
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

**Settings** > **Vehicle pages**. A page for every make, model, model year and Canadian trim of every year, at carmacars.ca/cars/make/model/year/trim, with our cars below it; each trim also in every place and in 12 colours (a black 2020 Volkswagen Jetta Sportline in Mississauga, for example); every page again for sale (carmacars.ca/buy/...) and for each search term: renting (car hire), sale (financing), detailing (ceramic coating) and body shop (bumper repair), at carmacars.ca/t/term/...

1. Pages: how many pages each level and each tier has, the total, and how many are in search. Every page is in search by default; nothing needs setting up.
2. One switch per tier takes it out of search at once: **Index the place pages**, **Index the colour pages**, **Index the search term pages**, **Index the /buy pages**, **Index the detailing pages**, **Index the body shop pages**. Off, those pages stay visible but leave the sitemaps and search.
3. The places are the place list of the local search release (every city, town and neighbourhood, with GTA and country levels); until it is filled, the area landing pages. The search terms are edited with them.
4. **Financing disclaimer**: the text on financing and leasing pages. CarmaCars never says it lends or leases.
5. Database: its size against the cap the catalog import keeps under (6,144 MB by default). IndexNow: the addresses sent today, where the sweep is, and any back-off; nothing to do.
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
3. "Find me this car" on the /buy pages sends a buyer lead to Sales (**Leads**, Buyer leads), with a To do line.

## Search engines and business listings

**Settings** > **All settings**, then Site settings.

1. Search engines: paste the Google Search Console value (HTML tag) or the file name (HTML file), and the Bing value. The steps are on the card.
2. Business name, address and phone: the exact text for every listing, and the description and categories.
3. Business listings: press **Copy** beside each line and paste it into Google Business Profile, Bing Places, Apple Business Connect, Yelp, Yellow Pages and Facebook. Tick each one when it is done.

> Good to know: Changed pages are sent to IndexNow (Bing and the other engines that use it) by themselves. Google reads the sitemap: submit carmacars.ca/sitemap.xml once in Search Console.
',
  '<p class="gd-p">The text of every car page, the landing pages for each area and way of renting, and the guides are written by Workers AI from the facts in the database, checked and published by themselves. Nobody has to type or review anything. You can still change any line; what you change is kept.</p><section class="gd-task" id="search-car-pages-landing-pages-and-guides-the-copy-of-a-car" data-gd-task><h2 class="gd-h2">The copy of a car</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Vehicles</b>, then the car, then its Listing tab. The same card is on the listing review.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The card says who wrote the text: a plain copy from the car&#39;s facts while the written copy is prepared (usually minutes), then Workers AI.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Every field is shown: search title and description, heading, introduction, highlights, good for, what&#39;s included, pickup and delivery, requirements, questions and the photo descriptions.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">To change a field press <b class="gd-ui">Change</b>, then <b class="gd-ui">Save and lock</b>. A locked field is kept by every new version. <b class="gd-ui">Unlock</b> lets it be written again.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Write again</b> asks for a new version now. A new version is also written by itself when the car&#39;s facts change: its rates, specs, area or photos.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>The checks refuse long dashes, sales words, the numbered company, any number that is not in the car&#39;s facts (a price, a seat count) and equipment the facts do not list. A version that fails is asked again with the problems named; if it still fails, the page keeps its current text and it is tried again later.</div></aside></section><section class="gd-task" id="search-car-pages-landing-pages-and-guides-landing-pages-and-guides" data-gd-task><h2 class="gd-h2">Landing pages and guides</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">All settings</b>, then Search.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Today: the Workers AI used for search copy and in all, and IndexNow (addresses waiting and sent).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Car copy: every real car, who wrote its text, and whether its facts changed since.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Landing pages: each place and way of renting, whether it is in search, its cars and who wrote it. A page for a way of renting (monthly, SUV) goes into search once enough real cars match it (Program settings).</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Open <b class="gd-ui">Edit</b> on a page or a guide to change its text. Edited fields are locked. <b class="gd-ui">Write again</b> asks for a new version; on a guide, the brief says what it must cover.</div></li></ol></div></section><section class="gd-task" id="search-car-pages-landing-pages-and-guides-vehicle-pages" data-gd-task><h2 class="gd-h2">Vehicle pages</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Vehicle pages</b>. A page for every make, model, model year and Canadian trim of every year, at carmacars.ca/cars/make/model/year/trim, with our cars below it; each trim also in every place and in 12 colours (a black 2020 Volkswagen Jetta Sportline in Mississauga, for example); every page again for sale (carmacars.ca/buy/...) and for each search term: renting (car hire), sale (financing), detailing (ceramic coating) and body shop (bumper repair), at carmacars.ca/t/term/...</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Pages: how many pages each level and each tier has, the total, and how many are in search. Every page is in search by default; nothing needs setting up.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">One switch per tier takes it out of search at once: <b class="gd-ui">Index the place pages</b>, <b class="gd-ui">Index the colour pages</b>, <b class="gd-ui">Index the search term pages</b>, <b class="gd-ui">Index the /buy pages</b>, <b class="gd-ui">Index the detailing pages</b>, <b class="gd-ui">Index the body shop pages</b>. Off, those pages stay visible but leave the sitemaps and search.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The places are the place list of the local search release (every city, town and neighbourhood, with GTA and country levels); until it is filled, the area landing pages. The search terms are edited with them.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Financing disclaimer</b>: the text on financing and leasing pages. CarmaCars never says it lends or leases.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Database: its size against the cap the catalog import keeps under (6,144 MB by default). IndexNow: the addresses sent today, where the sweep is, and any back-off; nothing to do.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Each page is built from data: the EPA fuel-use ratings in litres per 100 km, the cost to drive 100 km at the gas or electricity price set here, what changed from the year before, how a trim differs from the others, similar models, and the rental questions from the program settings.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Below the facts: our cars of that exact year, model and trim, then the same model in other years, then similar cars free now, and Request it, which sends an enquiry to Bookings &gt; Leads.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Settings: <b class="gd-ui">Index every page</b> (the default) or <b class="gd-ui">Only pages that pass the rules</b>: makes, models with 2 or more years of data, years with one of our cars or of a popular model from 2015, trims with one of our cars. The others stay visible but out of search. Also the gas, premium and electricity prices, and how often the catalog is imported (every 30 days).</div></li><li><span class="gd-n" aria-hidden="true">9</span><div class="gd-t">Canadian trims: open a model and type one line per run of years, entry trim first: 2020-2021: Comfortline, Highline, Sportline, Execline. Your lines are kept by every import; empty them to go back to the CarmaCars list. <b class="gd-ui">Add trims for another model</b> adds a model that has none.</div></li><li><span class="gd-n" aria-hidden="true">10</span><div class="gd-t">Catalog import: the last import and its counts. <b class="gd-ui">Import now</b> asks for a new one; it runs at the next daily check, at 07:17 UTC.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A car joins its pages by itself once it is on the site: its make, model, year and trim are read from the car. A trim that names several (S / SE / R-Line) leaves the car on the year page only; set the car&#39;s trim to one Canadian name to put it on the trim page.</div></aside></section><section class="gd-task" id="search-car-pages-landing-pages-and-guides-a-car-for-sale" data-gd-task><h2 class="gd-h2">A car for sale</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Vehicles</b>, then the car. On the For sale card, tick <b class="gd-ui">For sale</b>, enter the Asking price and press <b class="gd-ui">Save</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The car then shows at the top of its /buy pages (its make, model, year and trim) with the asking price, the only time a page says a car is for sale.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Untick it when the car is sold or no longer for sale: the pages say so at once.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">&quot;Find me this car&quot; on the /buy pages sends a buyer lead to Sales (<b class="gd-ui">Leads</b>, Buyer leads), with a To do line.</div></li></ol></div></section><section class="gd-task" id="search-car-pages-landing-pages-and-guides-search-engines-and-business-listings" data-gd-task><h2 class="gd-h2">Search engines and business listings</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">All settings</b>, then Site settings.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Search engines: paste the Google Search Console value (HTML tag) or the file name (HTML file), and the Bing value. The steps are on the card.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Business name, address and phone: the exact text for every listing, and the description and categories.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Business listings: press <b class="gd-ui">Copy</b> beside each line and paste it into Google Business Profile, Bing Places, Apple Business Connect, Yelp, Yellow Pages and Facebook. Tick each one when it is done.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Changed pages are sent to IndexNow (Bing and the other engines that use it) by themselves. Google reads the sitemap: submit carmacars.ca/sitemap.xml once in Search Console.</div></aside></section>');
select app.guide_release_section('admin', 'settings', 'chapter', 'search-car-pages-landing-pages-and-guides', 'Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.

## The Settings page

1. Site setup lists what is still missing on the public site, with **Open site settings**.
2. Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.
3. Program settings: every timing and policy value.
4. Forms: the official ServiceOntario PDFs and what goes in each field.
5. Insurers: insurance companies billed for bookings.

![](/guides/img/admin-24-settings-desktop-89b31691.jpg "desktop; size: 1440 900; address: carmacars.ca/admin/settings; pins: 1 32.6 33.0, 2 25.8 40.2, 3 77.4 40.2, 4 25.8 73.2, 5 25.8 84.9")

The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Airports and delivery, Coverage prices, Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.

## Program settings

1. Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.
2. Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.
3. First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.
4. Staff commissions and prices typed by hand: the commission outside Sales (10%), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month''s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%). The owner confirmed these values in October 2026.
5. Staff agreement defaults by function, at the bottom: pay (a month, an hour or commission only), the rate, the schedule (full time, part time or flexible), days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Sales is commission only: no rate and a flexible schedule. Press **Save the defaults**.
6. Live visitors and live chat: recording visits, the signal thresholds, follow-up tasks, the chat and its assistant, and how long visits and chats are kept.
7. Discount games: the same values as Settings, Discount games (the prize table and the games are easier to change there).
8. Calendar sync, Turo by email, Booking recovery emails and Site check: how often calendar links are read, the Turo inbound address and who may forward to it, the reminder delays and sending hours, and the site check with the address its alerts go to (rent@carmacars.ca), the minutes before an email, the daily limit and the quiet hours.
9. Change a value and press **Save**. It is saved as a new row from today; the rows before stay as they were.

![](/guides/img/admin-25-program-settings-desktop-d16b066c.jpg "desktop; size: 1440 1000; address: carmacars.ca/admin/settings/program; pins: 1 25.8 22.0, 2 27.8 49.0")

## Official ServiceOntario forms

The five official forms are loaded with a draft mapping to the owner, car, company and lender details. Until you check a form, owners get a data sheet with the values.

1. Open **Settings** > **Forms**. Each form shows "Mapping to check" (a draft is ready) or "Official PDF in use". Its notes say what the form is for and which boxes are left blank on purpose.
2. Press **Download a filled preview** for one car and check each value against the form.
3. Change a field if needed: What goes in it (or "The owner signs here"), a Format (for example YYYY/MM/DD) and Only when. Press Save the mapping.
4. Press **Checked: use for owners**. Every owner''s form of that kind is filled again, except ones already signed or filed, and owners sign it with their other documents.
5. A new version from ServiceOntario? Press **Upload the official fillable PDF**: the fields of the same name keep their mapping.

> Good to know: SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company''s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner''s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person.

## Agreements to sign: investors and staff

Investment agreements and staff agreements are made from the person''s record and signed in their own portal, or on paper.

1. Investor: open **People** > **Investors** and the investor. Under Investment agreement, press **Send the agreement to sign**. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press **Send to sign**.
2. Once the investor signs, the agreement shows **Awaiting countersignature** on the investor''s page and on To do. It is not countersigned automatically: check it and press **Countersign**. CarmaCars is bound once it has countersigned and the funds clear.
3. Staff: open **People** > **Staff**. Under Staff agreements, press **Send the agreement to sign** beside the person. Pay, schedule, hours and the other values start from the staff profile and the defaults of their function in Program settings; change any before sending. For Sales the Pay is Commission only: the agreement then has no rate, schedule or hours, and pays the commission of section 3.4.
4. A field staff member''s agreement prints the home address they entered themselves. Staff enter their home address at their first sign-in, before they sign, or in their profile.
5. They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.
6. Your own PDF instead? **Send a PDF to sign** still works.
7. Signed on paper instead? Press **Record paper signature** in the same place and upload the scan.
8. Sent by mistake? Press **Withdraw** and give the reason.

## The user guides

**Settings** > **Guides**. The guide of each portal, as people read it under Guide.

1. Each guide shows its version, when it was published and whether there are unpublished changes.
2. Open a guide and press a section. Change its text and press **Show the preview** to see it as people will. Press **Save the draft**; each save is kept in the section''s history.
3. Move a section with the arrows, hide it, or press **Add a chapter**. Upload a screenshot under Screenshots and paste the line it gives you.
4. Press **Publish version** (the next number). The portals show the new version at once.
5. The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.

## The guides keep up by themselves

After every update of the site that changes the portals, the guides are checked without anyone asking.

1. Every screenshot is taken again on the new version of the site. One whose screen changed replaces the old one in the guide.
2. The text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal''s own labels and menu, checked, and published. The PDFs of those guides are printed again.
3. Such a section says **Changed automatically on** and the date, in the list of guides and in the guide''s editor. Not right? Open the section and press **Revert**: the text it replaced comes back, published at once.
4. This includes sections you edited: the newest automatic text is published, and every earlier version stays in the section''s history. There is nothing to review.
5. A rewrite that does not pass the checks is asked again, more strictly. If it still does not pass, the screenshots and button names are updated, the rest of the text stays as it was, and the next run tries again.

> Tip: The card "The guides keep up by themselves" at the top of Guides lists the last runs: when, how many screenshots were replaced, how many sections were rewritten, and how many PDFs were printed.

## Insurers and the other lists

1. Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes.
2. To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press **Add**.
3. Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.
', 'Settings', 'Site, program settings, official forms mapping, insurers and the other lists.',
  'Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.

## The Settings page

1. Site setup lists what is still missing on the public site, with **Open site settings**.
2. Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.
3. Program settings: every timing and policy value.
4. Forms: the official ServiceOntario PDFs and what goes in each field.
5. Insurers: insurance companies billed for bookings.

![](/guides/img/admin-24-settings-desktop-89b31691.jpg "desktop; size: 1440 900; address: carmacars.ca/admin/settings; pins: 1 32.6 33.0, 2 25.8 40.2, 3 77.4 40.2, 4 25.8 73.2, 5 25.8 84.9")

The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Airports and delivery, Coverage prices, Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.

## Program settings

1. Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.
2. Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.
3. First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.
4. Staff commissions and prices typed by hand: the commission outside Sales (10%), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month''s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%). The owner confirmed these values in October 2026.
5. Staff agreement defaults by function, at the bottom: pay (a month, an hour or commission only), the rate, the schedule (full time, part time or flexible), days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Sales is commission only: no rate and a flexible schedule. Press **Save the defaults**.
6. Live visitors and live chat: recording visits, the signal thresholds, follow-up tasks, the chat and its assistant, and how long visits and chats are kept.
7. Discount games: the same values as Settings, Discount games (the prize table and the games are easier to change there).
8. Calendar sync, Turo by email, Booking recovery emails and Site check: how often calendar links are read, the Turo inbound address and who may forward to it, the reminder delays and sending hours, and the site check with the address its alerts go to (rent@carmacars.ca), the minutes before an email, the daily limit and the quiet hours.
9. Change a value and press **Save**. It is saved as a new row from today; the rows before stay as they were.

![](/guides/img/admin-25-program-settings-desktop-d16b066c.jpg "desktop; size: 1440 1000; address: carmacars.ca/admin/settings/program; pins: 1 25.8 22.0, 2 27.8 49.0")

## Official ServiceOntario forms

The five official forms are loaded with a draft mapping to the owner, car, company and lender details. Until you check a form, owners get a data sheet with the values.

1. Open **Settings** > **Forms**. Each form shows "Mapping to check" (a draft is ready) or "Official PDF in use". Its notes say what the form is for and which boxes are left blank on purpose.
2. Press **Download a filled preview** for one car and check each value against the form.
3. Change a field if needed: What goes in it (or "The owner signs here"), a Format (for example YYYY/MM/DD) and Only when. Press Save the mapping.
4. Press **Checked: use for owners**. Every owner''s form of that kind is filled again, except ones already signed or filed, and owners sign it with their other documents. Each form not checked yet is also a line on To do with the same button and Preview it.
5. A new version from ServiceOntario? Press **Upload the official fillable PDF**: the fields of the same name keep their mapping.

> Good to know: SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company''s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner''s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person.

## Agreements to sign: investors and staff

Investment agreements and staff agreements are made from the person''s record and signed in their own portal, or on paper.

1. Investor: open **People** > **Investors** and the investor. Under Investment agreement, press **Send the agreement to sign**. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press **Send to sign**.
2. Once the investor signs, the agreement shows **Awaiting countersignature** on the investor''s page and on To do. It is not countersigned automatically: check it and press **Countersign**. CarmaCars is bound once it has countersigned and the funds clear.
3. Staff: open **People** > **Staff**. Under Staff agreements, press **Send the agreement to sign** beside the person. Pay, schedule, hours and the other values start from the staff profile and the defaults of their function in Program settings; change any before sending. For Sales the Pay is Commission only: the agreement then has no rate, schedule or hours, and pays the commission of section 3.4.
4. A field staff member''s agreement prints the home address they entered themselves. Staff enter their home address at their first sign-in, before they sign, or in their profile.
5. They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.
6. Your own PDF instead? **Send a PDF to sign** still works.
7. Signed on paper instead? Press **Record paper signature** in the same place and upload the scan.
8. Sent by mistake? Press **Withdraw** and give the reason.

## The user guides

**Settings** > **Guides**. The guide of each portal, as people read it under Guide.

1. Each guide shows its version, when it was published and whether there are unpublished changes.
2. Open a guide and press a section. Change its text and press **Show the preview** to see it as people will. Press **Save the draft**; each save is kept in the section''s history.
3. Move a section with the arrows, hide it, or press **Add a chapter**. Upload a screenshot under Screenshots and paste the line it gives you.
4. Press **Publish version** (the next number). The portals show the new version at once.
5. The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.

## The guides keep up by themselves

After every update of the site that changes the portals, the guides are checked without anyone asking.

1. Every screenshot is taken again on the new version of the site. One whose screen changed replaces the old one in the guide.
2. The text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal''s own labels and menu, checked, and published. The PDFs of those guides are printed again.
3. Such a section says **Changed automatically on** and the date, in the list of guides and in the guide''s editor. Not right? Open the section and press **Revert**: the text it replaced comes back, published at once.
4. This includes sections you edited: the newest automatic text is published, and every earlier version stays in the section''s history. There is nothing to review.
5. A rewrite that does not pass the checks is asked again, more strictly. If it still does not pass, the screenshots and button names are updated, the rest of the text stays as it was, and the next run tries again.

> Tip: The card "The guides keep up by themselves" at the top of Guides lists the last runs: when, how many screenshots were replaced, how many sections were rewritten, and how many PDFs were printed.

## Insurers and the other lists

1. Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes.
2. To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press **Add**.
3. Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.
',
  '<p class="gd-p">Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.</p><section class="gd-task" id="settings-the-settings-page" data-gd-task><h2 class="gd-h2">The Settings page</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Site setup lists what is still missing on the public site, with <b class="gd-ui">Open site settings</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Program settings: every timing and policy value.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Forms: the official ServiceOntario PDFs and what goes in each field.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Insurers: insurance companies billed for bookings.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/900"><img src="/guides/img/admin-24-settings-desktop-89b31691.jpg" alt="" loading="lazy" decoding="async" width="1440" height="900"><span class="gd-pin" style="left:32.6%;top:33%" aria-hidden="true">1</span><span class="gd-pin" style="left:25.8%;top:40.2%" aria-hidden="true">2</span><span class="gd-pin" style="left:77.4%;top:40.2%" aria-hidden="true">3</span><span class="gd-pin" style="left:25.8%;top:73.2%" aria-hidden="true">4</span><span class="gd-pin" style="left:25.8%;top:84.9%" aria-hidden="true">5</span></div></div></figure></div><p class="gd-p">The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Airports and delivery, Coverage prices, Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.</p></section><section class="gd-task" id="settings-program-settings" data-gd-task><h2 class="gd-h2">Program settings</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Staff commissions and prices typed by hand: the commission outside Sales (10%), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month&#39;s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%). The owner confirmed these values in October 2026.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Staff agreement defaults by function, at the bottom: pay (a month, an hour or commission only), the rate, the schedule (full time, part time or flexible), days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Sales is commission only: no rate and a flexible schedule. Press <b class="gd-ui">Save the defaults</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Live visitors and live chat: recording visits, the signal thresholds, follow-up tasks, the chat and its assistant, and how long visits and chats are kept.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Discount games: the same values as Settings, Discount games (the prize table and the games are easier to change there).</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Calendar sync, Turo by email, Booking recovery emails and Site check: how often calendar links are read, the Turo inbound address and who may forward to it, the reminder delays and sending hours, and the site check with the address its alerts go to (rent@carmacars.ca), the minutes before an email, the daily limit and the quiet hours.</div></li><li><span class="gd-n" aria-hidden="true">9</span><div class="gd-t">Change a value and press <b class="gd-ui">Save</b>. It is saved as a new row from today; the rows before stay as they were.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings/program</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1000"><img src="/guides/img/admin-25-program-settings-desktop-d16b066c.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1000"><span class="gd-pin" style="left:25.8%;top:22%" aria-hidden="true">1</span><span class="gd-pin" style="left:27.8%;top:49%" aria-hidden="true">2</span></div></div></figure></div></section><section class="gd-task" id="settings-official-serviceontario-forms" data-gd-task><h2 class="gd-h2">Official ServiceOntario forms</h2><p class="gd-p">The five official forms are loaded with a draft mapping to the owner, car, company and lender details. Until you check a form, owners get a data sheet with the values.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Forms</b>. Each form shows &quot;Mapping to check&quot; (a draft is ready) or &quot;Official PDF in use&quot;. Its notes say what the form is for and which boxes are left blank on purpose.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Download a filled preview</b> for one car and check each value against the form.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Change a field if needed: What goes in it (or &quot;The owner signs here&quot;), a Format (for example YYYY/MM/DD) and Only when. Press Save the mapping.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Checked: use for owners</b>. Every owner&#39;s form of that kind is filled again, except ones already signed or filed, and owners sign it with their other documents. Each form not checked yet is also a line on To do with the same button and Preview it.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A new version from ServiceOntario? Press <b class="gd-ui">Upload the official fillable PDF</b>: the fields of the same name keep their mapping.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company&#39;s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner&#39;s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person.</div></aside></section><section class="gd-task" id="settings-agreements-to-sign-investors-and-staff" data-gd-task><h2 class="gd-h2">Agreements to sign: investors and staff</h2><p class="gd-p">Investment agreements and staff agreements are made from the person&#39;s record and signed in their own portal, or on paper.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Investor: open <b class="gd-ui">People</b> &gt; <b class="gd-ui">Investors</b> and the investor. Under Investment agreement, press <b class="gd-ui">Send the agreement to sign</b>. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press <b class="gd-ui">Send to sign</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Once the investor signs, the agreement shows <b class="gd-ui">Awaiting countersignature</b> on the investor&#39;s page and on To do. It is not countersigned automatically: check it and press <b class="gd-ui">Countersign</b>. CarmaCars is bound once it has countersigned and the funds clear.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Staff: open <b class="gd-ui">People</b> &gt; <b class="gd-ui">Staff</b>. Under Staff agreements, press <b class="gd-ui">Send the agreement to sign</b> beside the person. Pay, schedule, hours and the other values start from the staff profile and the defaults of their function in Program settings; change any before sending. For Sales the Pay is Commission only: the agreement then has no rate, schedule or hours, and pays the commission of section 3.4.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A field staff member&#39;s agreement prints the home address they entered themselves. Staff enter their home address at their first sign-in, before they sign, or in their profile.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Your own PDF instead? <b class="gd-ui">Send a PDF to sign</b> still works.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Signed on paper instead? Press <b class="gd-ui">Record paper signature</b> in the same place and upload the scan.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Sent by mistake? Press <b class="gd-ui">Withdraw</b> and give the reason.</div></li></ol></div></section><section class="gd-task" id="settings-the-user-guides" data-gd-task><h2 class="gd-h2">The user guides</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Guides</b>. The guide of each portal, as people read it under Guide.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each guide shows its version, when it was published and whether there are unpublished changes.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open a guide and press a section. Change its text and press <b class="gd-ui">Show the preview</b> to see it as people will. Press <b class="gd-ui">Save the draft</b>; each save is kept in the section&#39;s history.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Move a section with the arrows, hide it, or press <b class="gd-ui">Add a chapter</b>. Upload a screenshot under Screenshots and paste the line it gives you.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Publish version</b> (the next number). The portals show the new version at once.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.</div></li></ol></div></section><section class="gd-task" id="settings-the-guides-keep-up-by-themselves" data-gd-task><h2 class="gd-h2">The guides keep up by themselves</h2><p class="gd-p">After every update of the site that changes the portals, the guides are checked without anyone asking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Every screenshot is taken again on the new version of the site. One whose screen changed replaces the old one in the guide.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal&#39;s own labels and menu, checked, and published. The PDFs of those guides are printed again.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Such a section says <b class="gd-ui">Changed automatically on</b> and the date, in the list of guides and in the guide&#39;s editor. Not right? Open the section and press <b class="gd-ui">Revert</b>: the text it replaced comes back, published at once.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">This includes sections you edited: the newest automatic text is published, and every earlier version stays in the section&#39;s history. There is nothing to review.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A rewrite that does not pass the checks is asked again, more strictly. If it still does not pass, the screenshots and button names are updated, the rest of the text stays as it was, and the next run tries again.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The card &quot;The guides keep up by themselves&quot; at the top of Guides lists the last runs: when, how many screenshots were replaced, how many sections were rewritten, and how many PDFs were printed.</div></aside></section><section class="gd-task" id="settings-insurers-and-the-other-lists" data-gd-task><h2 class="gd-h2">Insurers and the other lists</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press <b class="gd-ui">Add</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.</div></li></ol></div></section>');
select app.guide_release_section('admin', 'add-ons', 'chapter', 'settings', 'Add-ons are things renters buy with a rental. They are on, with prices set, from the start: change any of them when you want.

## The catalogue

Open **Settings** > **Add-ons**.

1. Each add-on shows its price, whether it is on, the notice it needs, its stock and how many are booked in the next 30 days.
2. Press **Edit** to change it: name, short description, price, Priced (per trip, per day or per hour), the most per trip, the most days, the minimum hours, HST.
3. Price by car: one line each, such as suv premium = 110 or body:van = 110. The first that matches the car wins.
4. Which cars: only some classes, only some cars, cars left out, fuel types left out (prepaid fuel is not for electric cars), months (winter tires October to April).
5. Notice needed in hours, In stock for physical items, the most on one booking, staff confirmation (a chauffeur), a Fleet task to get it ready (flowers, a chauffeur), and Not refunded once its notice has started.
6. Press **Save**. Add a photo with **Add a photo**. **Add an add-on** at the bottom adds a new one; it stays off until it has a price.

| Add-on | As set at launch |
| --- | --- |
| Flowers | $150 a trip, 24 hours notice, Fleet prepares |
| Baby seat (rear-facing), Child seat | $15 a day, up to $75 a trip, 2 in stock each |
| Booster seat | $10 a day, up to $50 a trip, 2 in stock |
| Chauffeur | $45 an hour, 3 hours minimum, staff confirm, 24 hours notice |
| Umbrella, Phone charger | $5 a trip, 4 in stock each |
| Full tank of gas (prepaid) | $85 a trip; $110 for SUVs, vans and premium cars; not for electric cars |
| Winter tires | $15 a day, up to $150, October to April |

## Where renters and staff see them

- The car page (Add-ons, priced live) and step 4 of the request.
- Offers and rentals added by hand: staff tick them; a chauffeur is confirmed with the offer.
- The renter portal: add one until 24 hours before pickup (Program settings, addon_portal_cutoff_hours) or the add-on''s own notice, charged on the card on file.
- The agreement summary, the offer, the receipt and the statement list each add-on as a line.
- Field staff see what to put in the car on the handover, and the prepaid fuel note.

## The money

- Add-on revenue is CarmaCars'' own: never Owner Revenue or a partner''s share, and never in a commission or kickback base.
- The company statement shows Add-ons as its own income line (account 4150).
- A cancellation refunds add-ons by the booking''s tier, except one marked Not refunded once its notice has started.
- Removing a paid add-on after booking creates a refund for it, waiting for approval.
', 'Add-ons', 'The catalogue, prices, which cars, notice, stock, confirmation and the money.',
  'Add-ons are things renters buy with a rental. They are on, with prices set, from the start: change any of them when you want.

## The catalogue

Open **Settings** > **Add-ons**.

1. Each add-on shows its price, whether it is on, the notice it needs, its stock and how many are booked in the next 30 days.
2. Press **Edit** to change it: name, short description, price, Priced (per trip, per day or per hour), the most per trip, the most days, the minimum hours, HST.
3. Price by car: one line each, such as suv premium = 110 or body:van = 110. The first that matches the car wins.
4. Which cars: only some classes, only some cars, cars left out, fuel types left out (prepaid fuel is not for electric cars), months (winter tires October to April).
5. Notice needed in hours, In stock for physical items, the most on one booking, staff confirmation (a chauffeur), a Fleet task to get it ready (flowers, a chauffeur), and Not refunded once its notice has started.
6. Press **Save**. Add a photo with **Add a photo**. **Add an add-on** at the bottom adds a new one; it stays off until it has a price.

| Add-on | As set at launch |
| --- | --- |
| Flowers | $150 a trip, 24 hours notice, Fleet prepares |
| Baby seat (rear-facing), Child seat | $15 a day, up to $75 a trip, 2 in stock each |
| Booster seat | $10 a day, up to $50 a trip, 2 in stock |
| Chauffeur | $45 an hour, 3 hours minimum, staff confirm, 24 hours notice |
| Umbrella, Phone charger | $5 a trip, 4 in stock each |
| Full tank of gas (prepaid) | $85 a trip; $110 for SUVs, vans and premium cars; not for electric cars |
| Winter tires | $15 a day, up to $150, October to April |

## Where renters and staff see them

- The car page (Add-ons, priced live) and step 4 of the request.
- Offers and rentals added by hand: staff tick them; a chauffeur is confirmed with the offer.
- The renter portal: add one until 24 hours before pickup (Program settings, addon_portal_cutoff_hours) or the add-on''s own notice, charged on the card on file.
- The agreement summary, the offer, the receipt and the statement list each add-on as a line.
- Field staff see what to put in the car on the handover, and the prepaid fuel note.

## The money

- An add-on a renter adds with no card on file waits for payment: the renter pays it on the booking (**Pay for your add-ons**), and the Finance task closes by itself. Paid another way, record it on the booking.
- Add-on revenue is CarmaCars'' own: never Owner Revenue or a partner''s share, and never in a commission or kickback base.
- The company statement shows Add-ons as its own income line (account 4150).
- A cancellation refunds add-ons by the booking''s tier, except one marked Not refunded once its notice has started.
- Removing a paid add-on after booking creates a refund for it, waiting for approval.
',
  '<p class="gd-p">Add-ons are things renters buy with a rental. They are on, with prices set, from the start: change any of them when you want.</p><section class="gd-task" id="add-ons-the-catalogue" data-gd-task><h2 class="gd-h2">The catalogue</h2><p class="gd-p">Open <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Add-ons</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each add-on shows its price, whether it is on, the notice it needs, its stock and how many are booked in the next 30 days.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Edit</b> to change it: name, short description, price, Priced (per trip, per day or per hour), the most per trip, the most days, the minimum hours, HST.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Price by car: one line each, such as suv premium = 110 or body:van = 110. The first that matches the car wins.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Which cars: only some classes, only some cars, cars left out, fuel types left out (prepaid fuel is not for electric cars), months (winter tires October to April).</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Notice needed in hours, In stock for physical items, the most on one booking, staff confirmation (a chauffeur), a Fleet task to get it ready (flowers, a chauffeur), and Not refunded once its notice has started.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Press <b class="gd-ui">Save</b>. Add a photo with <b class="gd-ui">Add a photo</b>. <b class="gd-ui">Add an add-on</b> at the bottom adds a new one; it stays off until it has a price.</div></li></ol></div><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Add-on</th><th scope="col">As set at launch</th></tr></thead><tbody><tr><td>Flowers</td><td>$150 a trip, 24 hours notice, Fleet prepares</td></tr><tr><td>Baby seat (rear-facing), Child seat</td><td>$15 a day, up to $75 a trip, 2 in stock each</td></tr><tr><td>Booster seat</td><td>$10 a day, up to $50 a trip, 2 in stock</td></tr><tr><td>Chauffeur</td><td>$45 an hour, 3 hours minimum, staff confirm, 24 hours notice</td></tr><tr><td>Umbrella, Phone charger</td><td>$5 a trip, 4 in stock each</td></tr><tr><td>Full tank of gas (prepaid)</td><td>$85 a trip; $110 for SUVs, vans and premium cars; not for electric cars</td></tr><tr><td>Winter tires</td><td>$15 a day, up to $150, October to April</td></tr></tbody></table></div></section><section class="gd-task" id="add-ons-where-renters-and-staff-see-them" data-gd-task><h2 class="gd-h2">Where renters and staff see them</h2><ul class="gd-ul"><li>The car page (Add-ons, priced live) and step 4 of the request.</li><li>Offers and rentals added by hand: staff tick them; a chauffeur is confirmed with the offer.</li><li>The renter portal: add one until 24 hours before pickup (Program settings, addon_portal_cutoff_hours) or the add-on&#39;s own notice, charged on the card on file.</li><li>The agreement summary, the offer, the receipt and the statement list each add-on as a line.</li><li>Field staff see what to put in the car on the handover, and the prepaid fuel note.</li></ul></section><section class="gd-task" id="add-ons-the-money" data-gd-task><h2 class="gd-h2">The money</h2><ul class="gd-ul"><li>An add-on a renter adds with no card on file waits for payment: the renter pays it on the booking (<b class="gd-ui">Pay for your add-ons</b>), and the Finance task closes by itself. Paid another way, record it on the booking.</li><li>Add-on revenue is CarmaCars&#39; own: never Owner Revenue or a partner&#39;s share, and never in a commission or kickback base.</li><li>The company statement shows Add-ons as its own income line (account 4150).</li><li>A cancellation refunds add-ons by the booking&#39;s tier, except one marked Not refunded once its notice has started.</li><li>Removing a paid add-on after booking creates a refund for it, waiting for approval.</li></ul></section>');
select app.guide_release_section('admin', 'the-investor-deck', 'chapter', 'add-ons', null, 'The investor deck', 'Preview the deck, show or hide it, and set its multiplier and percentage.',
  'The investor deck is a slide deck in the investor portal at `/investor/deck`. Signed-in investors see it while it is shown; Admins always see it. Its figures come from the database when it opens: the owner fee tiers, the partner commission, the real cars'' public rates, delivery, add-ons and renter fees, the deductible and deposits, and the investment terms of Program settings.

## Preview and settings

1. Go to **Investors** and press **Investor deck**. The button says whether investors see it now.
2. The page shows the settings, then the whole deck as investors see it.
3. **Show the deck to investors**: on, investors see it under Investor deck and on their Investments page; off, only Admins see it.
4. **Multiplier on the money we invest (x)**: the company''s own figure, shown large on the profitability slide with its footnote (internal, not audited).
5. **Yearly percentage of the current offer (%)**: used by the worked examples and the calculator. Each investor''s own percentage is the one in their agreement.
6. Press **Save deck settings**. Every change is in the audit log.

To hide or show it in one click, use **Hide the deck from investors** or **Show the deck to investors** on Investors.

> Good to know: The deck shows no internal costs, fleet counts or staff pay. Every example is labelled as an illustration, with the forward-looking statements notice on every slide and in the PDF.
',
  '<p class="gd-p">The investor deck is a slide deck in the investor portal at <span class="gd-url">/investor/deck</span>. Signed-in investors see it while it is shown; Admins always see it. Its figures come from the database when it opens: the owner fee tiers, the partner commission, the real cars&#39; public rates, delivery, add-ons and renter fees, the deductible and deposits, and the investment terms of Program settings.</p><section class="gd-task" id="the-investor-deck-preview-and-settings" data-gd-task><h2 class="gd-h2">Preview and settings</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Go to <b class="gd-ui">Investors</b> and press <b class="gd-ui">Investor deck</b>. The button says whether investors see it now.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The page shows the settings, then the whole deck as investors see it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Show the deck to investors</b>: on, investors see it under Investor deck and on their Investments page; off, only Admins see it.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Multiplier on the money we invest (x)</b>: the company&#39;s own figure, shown large on the profitability slide with its footnote (internal, not audited).</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><b class="gd-ui">Yearly percentage of the current offer (%)</b>: used by the worked examples and the calculator. Each investor&#39;s own percentage is the one in their agreement.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Press <b class="gd-ui">Save deck settings</b>. Every change is in the audit log.</div></li></ol></div><p class="gd-p">To hide or show it in one click, use <b class="gd-ui">Hide the deck from investors</b> or <b class="gd-ui">Show the deck to investors</b> on Investors.</p><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>The deck shows no internal costs, fleet counts or staff pay. Every example is labelled as an illustration, with the forward-looking statements notice on every slide and in the PDF.</div></aside></section>');
select app.guide_release_section('admin', 'assistant', 'chapter', 'the-investor-deck', null, 'Assistant', 'Ask about today, bookings, cars and money; confirm the changes it prepares.',
  'The assistant answers questions from live data and prepares changes for you. It works only through the same steps as the screens, with your own permissions: it cannot see or do anything you could not do yourself. Nothing changes until you confirm.

## Open it

Press **Assistant** at the top of the menu, or press Ctrl and / together (Cmd and / on a Mac). Esc closes it.

1. Type a question or what you want done, in your own words, and press Enter. Examples: "What needs doing today?", "Who has the Tesla?", "Is the Corolla free from 2026-11-02 to 2026-11-04?", "Find booking R-000123".
2. Answers come as cards with links: open one to go straight to the screen.
3. If something is missing or more than one thing matches, it asks and lists the choices. Press the one you mean.

## Changes: a card to confirm

1. Ask for a change, for example "Record a $900 e-Transfer on INV-1053 dated 2026-10-15 reference CA12345".
2. The assistant shows a card: "Record a $900 e-Transfer on INV-1053 for Karan Vakil, dated Oct 15?". Read it, then press **Confirm** or **Cancel**.
3. Confirmed, it runs the same step as the screen and its pop-up, with the same checks. If the step is not allowed for you, or a detail is wrong, it says why and nothing changes.
4. Every change is in the audit log under your name, marked "via assistant". A card older than 30 minutes no longer runs: ask again.

When the insurer''s email arrives, say so: "The insurer confirmed CC-7F3A on 2026-10-20". The card marks the car insured as To do''s Insurer confirmed does, from the date of the email. A car is found by its name, its plate or its car code (CC- and four characters, on the car page and in the chat).

Messages: ask it to draft a message to a renter or an owner. It writes the text; press **Copy**, open the conversation and send it yourself.

> Tip: When the day''s included AI usage is used, the assistant says it is unavailable until tomorrow. Everything still works from the screens and pop-ups.
',
  '<p class="gd-p">The assistant answers questions from live data and prepares changes for you. It works only through the same steps as the screens, with your own permissions: it cannot see or do anything you could not do yourself. Nothing changes until you confirm.</p><section class="gd-task" id="assistant-open-it" data-gd-task><h2 class="gd-h2">Open it</h2><p class="gd-p">Press <b class="gd-ui">Assistant</b> at the top of the menu, or press Ctrl and / together (Cmd and / on a Mac). Esc closes it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Type a question or what you want done, in your own words, and press Enter. Examples: &quot;What needs doing today?&quot;, &quot;Who has the Tesla?&quot;, &quot;Is the Corolla free from 2026-11-02 to 2026-11-04?&quot;, &quot;Find booking R-000123&quot;.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Answers come as cards with links: open one to go straight to the screen.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">If something is missing or more than one thing matches, it asks and lists the choices. Press the one you mean.</div></li></ol></div></section><section class="gd-task" id="assistant-changes-a-card-to-confirm" data-gd-task><h2 class="gd-h2">Changes: a card to confirm</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Ask for a change, for example &quot;Record a $900 e-Transfer on INV-1053 dated 2026-10-15 reference CA12345&quot;.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The assistant shows a card: &quot;Record a $900 e-Transfer on INV-1053 for Karan Vakil, dated Oct 15?&quot;. Read it, then press <b class="gd-ui">Confirm</b> or <b class="gd-ui">Cancel</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Confirmed, it runs the same step as the screen and its pop-up, with the same checks. If the step is not allowed for you, or a detail is wrong, it says why and nothing changes.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Every change is in the audit log under your name, marked &quot;via assistant&quot;. A card older than 30 minutes no longer runs: ask again.</div></li></ol></div><p class="gd-p">When the insurer&#39;s email arrives, say so: &quot;The insurer confirmed CC-7F3A on 2026-10-20&quot;. The card marks the car insured as To do&#39;s Insurer confirmed does, from the date of the email. A car is found by its name, its plate or its car code (CC- and four characters, on the car page and in the chat).</p><p class="gd-p">Messages: ask it to draft a message to a renter or an owner. It writes the text; press <b class="gd-ui">Copy</b>, open the conversation and send it yourself.</p><aside class="gd-box"><span class="gd-lbl">Tip</span><div>When the day&#39;s included AI usage is used, the assistant says it is unavailable until tomorrow. Everything still works from the screens and pop-ups.</div></aside></section>');
select app.guide_release_section('admin', 'usage-and-paid-usage', 'chapter', 'assistant', null, 'Usage and paid usage', 'Included allowances, the 80% and used-up alerts, allowing paid usage, what pauses and what never does.',
  'The plans CarmaCars runs on include a free allowance: AI, the website, image transformations, emails, the database and storage. When an allowance runs out, AI and photo features pause with a short message until it resets, and you are asked before anything is paid.

## The alerts

At 80% of an allowance you get one quiet card on **To do** and one email to the alert address. When it is used up, a second card and email.

1. A used-up AI or image allowance shows "Included ... used up for today: Allow paid usage". Press **Allow paid usage** to see what continuing costs at the current rates.
2. Choose until the end of today or this month, type the most it may cost (for example $1), and press the Allow button. Or press Keep paused.
3. Nobody answering keeps it paused: nothing is charged. Live chat goes to a person, AI copy waits with the template text, Turo emails are read by the rules, photos keep their original background, the assistant rests.
4. The website and the portals are never paused (that would stop bookings): their card shows the estimated cost, usually cents.

## Settings > Usage

Open **Settings**, then **Usage**: every service, used against included, when it resets, paid usage and the last 30 days.

1. Press **Change the allowance** after a plan change (for example a Supabase or Resend upgrade).
2. Supabase egress is not readable automatically: press **Enter a figure** with the number from the Supabase dashboard.
3. Emails cannot be paid on the free plan: when the daily or monthly count is used, booking, payment and sign-in emails still go first and the others wait. A banner on To do says so.
',
  '<p class="gd-p">The plans CarmaCars runs on include a free allowance: AI, the website, image transformations, emails, the database and storage. When an allowance runs out, AI and photo features pause with a short message until it resets, and you are asked before anything is paid.</p><section class="gd-task" id="usage-and-paid-usage-the-alerts" data-gd-task><h2 class="gd-h2">The alerts</h2><p class="gd-p">At 80% of an allowance you get one quiet card on <b class="gd-ui">To do</b> and one email to the alert address. When it is used up, a second card and email.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A used-up AI or image allowance shows &quot;Included ... used up for today: Allow paid usage&quot;. Press <b class="gd-ui">Allow paid usage</b> to see what continuing costs at the current rates.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose until the end of today or this month, type the most it may cost (for example $1), and press the Allow button. Or press Keep paused.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Nobody answering keeps it paused: nothing is charged. Live chat goes to a person, AI copy waits with the template text, Turo emails are read by the rules, photos keep their original background, the assistant rests.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The website and the portals are never paused (that would stop bookings): their card shows the estimated cost, usually cents.</div></li></ol></div></section><section class="gd-task" id="usage-and-paid-usage-settings-usage" data-gd-task><h2 class="gd-h2">Settings &gt; Usage</h2><p class="gd-p">Open <b class="gd-ui">Settings</b>, then <b class="gd-ui">Usage</b>: every service, used against included, when it resets, paid usage and the last 30 days.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Change the allowance</b> after a plan change (for example a Supabase or Resend upgrade).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Supabase egress is not readable automatically: press <b class="gd-ui">Enter a figure</b> with the number from the Supabase dashboard.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Emails cannot be paid on the free plan: when the daily or monthly count is used, booking, payment and sign-in emails still go first and the others wait. A banner on To do says so.</div></li></ol></div></section>');
select app.guide_release_section('admin', 'quick-reference', 'reference', 'email-backups-and-site-health', '### Where things are

| Item | What it is for |
| --- | --- |
| **To do** | What needs you now, most urgent first |
| **Search** | Any booking, plate, VIN, name or email |
| **Bookings** | Requests, bookings, the calendar, adding a rental |
| **Cars** | Vehicles, listings, calendar sync, sample photos |
| **Owners and partners** | Applications, owners, partners, owner forms |
| **Money** | Owner invoices and debits, payments, statements, tolls |
| **People** | Renters, staff, investors, View as |
| **Settings** | Site, program, forms, guides, emails, audit log |

### Top tasks

1. *Answer an application:* **Owners and partners** > **Applications**, then **Approve**, **Ask for something** or **Decline**
2. *Send an offer:* **Bookings** > **Requests**, the booking, then **Send the offer**
3. *Change a booking:* The booking''s Changes tab, then **Send to the renter**
4. *Publish a listing:* **Cover the plate**, then **Approve and publish**
5. *Let someone in:* **People** > **Portals and view as**, then **Invite**
6. *Help someone sign in:* **Send password link**
7. *Read a toll notice:* **Money** > **Tolls and tickets**, then **Read a notice**
8. *Monthly statements:* **Build all for a month**, Approve, Issue

### If something goes wrong

| What you see | What to do |
| --- | --- |
| **A link says it expired** | Links in our emails work for 24 hours, once. Press **Send me a new link** on that page. |
| **"Error 1102" on a page** | A short limit on our web host. Reload the page. You are still signed in. |
| **"That email and password do not match an account."** | Check the address, or use **Set a new password** on the sign-in page. |
| **You can''t change anything** | You are viewing as someone. Press Exit on the red banner. |
| **Asked for a 6-digit code** | Open your authenticator app. Lost phone: remove the factor in the Supabase dashboard. |
', 'Quick reference', 'One page with the essentials.',
  '### Where things are

| Item | What it is for |
| --- | --- |
| **To do** | What needs you now, most urgent first |
| **Search** | Any booking, plate, VIN, name or email |
| **Bookings** | Requests, bookings, the calendar, adding a rental |
| **Cars** | Vehicles, listings, calendar sync, sample photos |
| **Owners and partners** | Applications, owners, partners, owner forms |
| **Money** | Owner invoices and debits, payments, statements, tolls |
| **People** | Renters, staff, investors, View as |
| **Settings** | Site, program, forms, guides, emails, audit log |

### Top tasks

1. *Answer an application:* **Owners and partners** > **Applications**, then **Approve**, **Ask for something** or **Decline**
2. *Send an offer:* **Bookings** > **Requests**, the booking, then **Send the offer**
3. *Change a booking:* The booking''s Changes tab, then **Send to the renter**
4. *Publish a car:* To do, the car''s line, then **Set rates and publish**
5. *Mark a car insured:* To do, the car''s line, then **Mark insured**
6. *Check renter documents:* To do, the booking''s line, then **Review documents**
7. *Let someone in:* **People** > **Portals and view as**, then **Invite**
8. *Help someone sign in:* **Send password link**
9. *Read a toll notice:* **Money** > **Tolls and tickets**, then **Read a notice**
10. *Monthly statements:* **Build all for a month**, Approve, Issue

### If something goes wrong

| What you see | What to do |
| --- | --- |
| **A link says it expired** | Links in our emails work for 24 hours, once. Press **Send me a new link** on that page. |
| **"Error 1102" on a page** | A short limit on our web host. Reload the page. You are still signed in. |
| **"That email and password do not match an account."** | Check the address, or use **Set a new password** on the sign-in page. |
| **You can''t change anything** | You are viewing as someone. Press Exit on the red banner. |
| **Asked for a 6-digit code** | Open your authenticator app. Lost phone: remove the factor in the Supabase dashboard. |
',
  '<h3 class="gd-h3">Where things are</h3><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Item</th><th scope="col">What it is for</th></tr></thead><tbody><tr><td><b class="gd-ui">To do</b></td><td>What needs you now, most urgent first</td></tr><tr><td><b class="gd-ui">Search</b></td><td>Any booking, plate, VIN, name or email</td></tr><tr><td><b class="gd-ui">Bookings</b></td><td>Requests, bookings, the calendar, adding a rental</td></tr><tr><td><b class="gd-ui">Cars</b></td><td>Vehicles, listings, calendar sync, sample photos</td></tr><tr><td><b class="gd-ui">Owners and partners</b></td><td>Applications, owners, partners, owner forms</td></tr><tr><td><b class="gd-ui">Money</b></td><td>Owner invoices and debits, payments, statements, tolls</td></tr><tr><td><b class="gd-ui">People</b></td><td>Renters, staff, investors, View as</td></tr><tr><td><b class="gd-ui">Settings</b></td><td>Site, program, forms, guides, emails, audit log</td></tr></tbody></table></div><h3 class="gd-h3">Top tasks</h3><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><em>Answer an application:</em> <b class="gd-ui">Owners and partners</b> &gt; <b class="gd-ui">Applications</b>, then <b class="gd-ui">Approve</b>, <b class="gd-ui">Ask for something</b> or <b class="gd-ui">Decline</b></div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><em>Send an offer:</em> <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Requests</b>, the booking, then <b class="gd-ui">Send the offer</b></div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><em>Change a booking:</em> The booking&#39;s Changes tab, then <b class="gd-ui">Send to the renter</b></div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><em>Publish a car:</em> To do, the car&#39;s line, then <b class="gd-ui">Set rates and publish</b></div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><em>Mark a car insured:</em> To do, the car&#39;s line, then <b class="gd-ui">Mark insured</b></div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t"><em>Check renter documents:</em> To do, the booking&#39;s line, then <b class="gd-ui">Review documents</b></div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t"><em>Let someone in:</em> <b class="gd-ui">People</b> &gt; <b class="gd-ui">Portals and view as</b>, then <b class="gd-ui">Invite</b></div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t"><em>Help someone sign in:</em> <b class="gd-ui">Send password link</b></div></li><li><span class="gd-n" aria-hidden="true">9</span><div class="gd-t"><em>Read a toll notice:</em> <b class="gd-ui">Money</b> &gt; <b class="gd-ui">Tolls and tickets</b>, then <b class="gd-ui">Read a notice</b></div></li><li><span class="gd-n" aria-hidden="true">10</span><div class="gd-t"><em>Monthly statements:</em> <b class="gd-ui">Build all for a month</b>, Approve, Issue</div></li></ol></div><h3 class="gd-h3">If something goes wrong</h3><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">What you see</th><th scope="col">What to do</th></tr></thead><tbody><tr><td><b class="gd-ui">A link says it expired</b></td><td>Links in our emails work for 24 hours, once. Press <b class="gd-ui">Send me a new link</b> on that page.</td></tr><tr><td><b class="gd-ui">&quot;Error 1102&quot; on a page</b></td><td>A short limit on our web host. Reload the page. You are still signed in.</td></tr><tr><td><b class="gd-ui">&quot;That email and password do not match an account.&quot;</b></td><td>Check the address, or use <b class="gd-ui">Set a new password</b> on the sign-in page.</td></tr><tr><td><b class="gd-ui">You can&#39;t change anything</b></td><td>You are viewing as someone. Press Exit on the red banner.</td></tr><tr><td><b class="gd-ui">Asked for a 6-digit code</b></td><td>Open your authenticator app. Lost phone: remove the factor in the Supabase dashboard.</td></tr></tbody></table></div>');
select app.guide_release_section('va', 'your-workday', 'chapter', 'start-here', 'Every function works the same way: start on To do, take the oldest task, finish it, and check Today for pickups and returns. The menu keeps your own work first, then the screens of your function in a few groups.

## The menu

My work comes first: To do, Today, My scorecard and My sales (customer service and Sales also have Live visitors, Live chat and Game leads). Then the groups of your function. The current group is open; press another to open it. On a phone the whole menu sits behind one Menu button.

| Function | Groups and pages |
| --- | --- |
| Customer service | Bookings (Requests, New quote, Add a rental, Calendar), Renters (Messages, Find a renter), Cars (Listings, Similar cars), Owners (Owners and enquiries, Add a car for an owner, Owner forms) |
| Sales | Bookings (Requests and offers, New quote, Add a rental, Calendar), Owners (Owner leads) |
| Finance | Money (Payments, deposits and refunds, Tolls and tickets, Reconciliation, Turo trips), Renters and bookings (Find a renter, Calendar), Rentals (Add a rental, New quote) |
| Fleet | Field work (Field jobs, Daily checks, Photo reviews), Cars (Listings, Similar cars, Calendar, Calendar sync, Add a car for an owner), Renters (Find a renter), Rentals (Add a rental, New quote) |

## To do

Tasks come to your function on their own: new requests, renter replies, failed payments, toll notices and more.

1. The top line shows your function and how many tasks are open.
2. Filter: All, Mine, Unassigned or Waiting; Any time, Overdue, Due today or Escalated; and by type.
3. Each row has a priority, the task, its record, when it is due and how long it has waited. The oldest due is first.
4. Press **Take it** to make it yours. **Sheet** opens the step-by-step procedure.

![](/guides/img/va-cs-01-queue-desktop-c36a8e2d.jpg "desktop; size: 1440 640; address: carmacars.ca/va; pins: 1 13.9 5.0, 2 36.1 17.5, 3 31.9 43.8, 4 91.7 52.3")

## Work a task

Open the task. The buttons along the top move it on.

| Button | What it does |
| --- | --- |
| **Open the working screen** | Jumps to the booking, car or owner the task is about. |
| **Done** | You finished it. It leaves the queue. |
| **Waiting** | You are waiting on someone (a renter, an owner). It stays yours. |
| **Escalate** | It needs an Admin. Add why. |
| **Hand over** | Give it to someone else on the team. |
| **Add a note** | Leave a note for whoever looks next. |

> Tip: Work oldest due first. A task meets its target when it is done by its due time; that is what your scorecard counts.

## Today

1. Today lists pickups and returns, and what is due, for your function.
2. Press a booking number to open it. **To do** takes you back to your tasks.

![](/guides/img/va-cs-02-today-desktop-dfd277b7.jpg "desktop; size: 1440 700; address: carmacars.ca/va/today; pins: 1 20.8 14.3")

## Documents to sign

Your staff agreement, when CarmaCars sends it.

1. The queue shows "You have a document to sign". Press **Read and sign**.
2. Check the key values at the top (your role, hours, rate and start date), then press **Read the PDF** and read it.
3. Press **Sign**. Your full legal name is your signature (or press **Draw instead**). Several documents? One signature covers all of them. The signed copy stays on the same page.

## Several functions? Switch with Working as

If you cover more than one function, **Working as** above the menu lists them: Customer service, Finance, Fleet and Sales. Choose one; the menu, To do and Today change to that function.

## Your scorecard

1. Open **My work** > **My scorecard**.
2. By week shows each measure, its target and your result for each week.
3. A task meets its target when done by its due time. Daily checks count when done by 9:00 and 18:00.
4. The first reply target is 5 minutes: a new booking request, an enquiry, a change the renter asked for or a renter message is due 5 minutes after it comes in. An Admin sets it in Program settings, and the target column shows the one in force.

![](/guides/img/va-sales-05-scorecard-desktop-78ec1b03.jpg "desktop; size: 1440 360; address: carmacars.ca/va/scorecard; pins: 1 4.2 39.7, 2 62.5 58.3")
', 'Your workday', 'The menu, To do, task actions, Today, switching functions and your scorecard.',
  'Every function works the same way: start on To do, take the oldest task, finish it, and check Today for pickups and returns. The menu keeps your own work first, then the screens of your function in a few groups.

## The menu

My work comes first: To do, Today, My scorecard and My sales (customer service and Sales also have Live visitors, Live chat and Game leads). Then the groups of your function. The current group is open; press another to open it. On a phone the whole menu sits behind one Menu button.

| Function | Groups and pages |
| --- | --- |
| Customer service | Bookings (Requests, New quote, Add a rental, Calendar), Renters (Messages, Find a renter), Cars (Listings, Similar cars), Owners (Owners and enquiries, Add a car for an owner, Owner forms) |
| Sales | Bookings (Requests and offers, New quote, Add a rental, Calendar), Owners (Owner leads) |
| Finance | Money (Payments, deposits and refunds, Tolls and tickets, Reconciliation, Turo trips), Renters and bookings (Find a renter, Calendar), Rentals (Add a rental, New quote) |
| Fleet | Field work (Field jobs, Daily checks, Photo reviews), Cars (Listings, Similar cars, Calendar, Calendar sync, Add a car for an owner), Renters (Find a renter), Rentals (Add a rental, New quote) |

## To do

Tasks come to your function on their own: new requests, renter replies, failed payments, toll notices and more.

1. The top line shows your function and how many tasks are open.
2. Filter: All, Mine, Unassigned or Waiting; Any time, Overdue, Due today or Escalated; and by type.
3. Each row has a priority, the task, its record, when it is due and how long it has waited. The oldest due is first.
4. Press **Take it** to make it yours. Pressing the task opens the screen where it is done: a chat waiting for a person opens that chat, documents to check open the review, a request opens the booking. **Sheet** opens the step-by-step procedure.
5. Tasks close by themselves when their work is done elsewhere (an invoice paid or voided, a chat answered or closed); a day''s opening and closing checks close at the end of that day.

![](/guides/img/va-cs-01-queue-desktop-c36a8e2d.jpg "desktop; size: 1440 640; address: carmacars.ca/va; pins: 1 13.9 5.0, 2 36.1 17.5, 3 31.9 43.8, 4 91.7 52.3")

## Work a task

Open the task. The buttons along the top move it on.

| Button | What it does |
| --- | --- |
| **Open the working screen** | Jumps to the booking, car or owner the task is about. |
| **Done** | You finished it. It leaves the queue. |
| **Waiting** | You are waiting on someone (a renter, an owner). It stays yours. |
| **Escalate** | It needs an Admin. Add why. |
| **Hand over** | Give it to someone else on the team. |
| **Add a note** | Leave a note for whoever looks next. |

> Tip: Work oldest due first. A task meets its target when it is done by its due time; that is what your scorecard counts.

## Today

1. Today lists pickups and returns, and what is due, for your function.
2. Press a booking number to open it. **To do** takes you back to your tasks.

![](/guides/img/va-cs-02-today-desktop-dfd277b7.jpg "desktop; size: 1440 700; address: carmacars.ca/va/today; pins: 1 20.8 14.3")

## Documents to sign

Your staff agreement, when CarmaCars sends it.

1. The queue shows "You have a document to sign". Press **Read and sign**.
2. Check the key values at the top (your role, hours, rate and start date), then press **Read the PDF** and read it.
3. Press **Sign**. Your full legal name is your signature (or press **Draw instead**). Several documents? One signature covers all of them. The signed copy stays on the same page.

## Several functions? Switch with Working as

If you cover more than one function, **Working as** above the menu lists them: Customer service, Finance, Fleet and Sales. Choose one; the menu, To do and Today change to that function.

## Your scorecard

1. Open **My work** > **My scorecard**.
2. By week shows each measure, its target and your result for each week.
3. A task meets its target when done by its due time. Daily checks count when done by 9:00 and 18:00.
4. The first reply target is 5 minutes: a new booking request, an enquiry, a change the renter asked for or a renter message is due 5 minutes after it comes in. An Admin sets it in Program settings, and the target column shows the one in force.

![](/guides/img/va-sales-05-scorecard-desktop-78ec1b03.jpg "desktop; size: 1440 360; address: carmacars.ca/va/scorecard; pins: 1 4.2 39.7, 2 62.5 58.3")
',
  '<p class="gd-p">Every function works the same way: start on To do, take the oldest task, finish it, and check Today for pickups and returns. The menu keeps your own work first, then the screens of your function in a few groups.</p><section class="gd-task" id="your-workday-the-menu" data-gd-task><h2 class="gd-h2">The menu</h2><p class="gd-p">My work comes first: To do, Today, My scorecard and My sales (customer service and Sales also have Live visitors, Live chat and Game leads). Then the groups of your function. The current group is open; press another to open it. On a phone the whole menu sits behind one Menu button.</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Function</th><th scope="col">Groups and pages</th></tr></thead><tbody><tr><td>Customer service</td><td>Bookings (Requests, New quote, Add a rental, Calendar), Renters (Messages, Find a renter), Cars (Listings, Similar cars), Owners (Owners and enquiries, Add a car for an owner, Owner forms)</td></tr><tr><td>Sales</td><td>Bookings (Requests and offers, New quote, Add a rental, Calendar), Owners (Owner leads)</td></tr><tr><td>Finance</td><td>Money (Payments, deposits and refunds, Tolls and tickets, Reconciliation, Turo trips), Renters and bookings (Find a renter, Calendar), Rentals (Add a rental, New quote)</td></tr><tr><td>Fleet</td><td>Field work (Field jobs, Daily checks, Photo reviews), Cars (Listings, Similar cars, Calendar, Calendar sync, Add a car for an owner), Renters (Find a renter), Rentals (Add a rental, New quote)</td></tr></tbody></table></div></section><section class="gd-task" id="your-workday-to-do" data-gd-task><h2 class="gd-h2">To do</h2><p class="gd-p">Tasks come to your function on their own: new requests, renter replies, failed payments, toll notices and more.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The top line shows your function and how many tasks are open.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Filter: All, Mine, Unassigned or Waiting; Any time, Overdue, Due today or Escalated; and by type.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Each row has a priority, the task, its record, when it is due and how long it has waited. The oldest due is first.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Take it</b> to make it yours. Pressing the task opens the screen where it is done: a chat waiting for a person opens that chat, documents to check open the review, a request opens the booking. <b class="gd-ui">Sheet</b> opens the step-by-step procedure.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Tasks close by themselves when their work is done elsewhere (an invoice paid or voided, a chat answered or closed); a day&#39;s opening and closing checks close at the end of that day.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/640"><img src="/guides/img/va-cs-01-queue-desktop-c36a8e2d.jpg" alt="" loading="lazy" decoding="async" width="1440" height="640"><span class="gd-pin" style="left:13.9%;top:5%" aria-hidden="true">1</span><span class="gd-pin" style="left:36.1%;top:17.5%" aria-hidden="true">2</span><span class="gd-pin" style="left:31.9%;top:43.8%" aria-hidden="true">3</span><span class="gd-pin" style="left:91.7%;top:52.3%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="your-workday-work-a-task" data-gd-task><h2 class="gd-h2">Work a task</h2><p class="gd-p">Open the task. The buttons along the top move it on.</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Button</th><th scope="col">What it does</th></tr></thead><tbody><tr><td><b class="gd-ui">Open the working screen</b></td><td>Jumps to the booking, car or owner the task is about.</td></tr><tr><td><b class="gd-ui">Done</b></td><td>You finished it. It leaves the queue.</td></tr><tr><td><b class="gd-ui">Waiting</b></td><td>You are waiting on someone (a renter, an owner). It stays yours.</td></tr><tr><td><b class="gd-ui">Escalate</b></td><td>It needs an Admin. Add why.</td></tr><tr><td><b class="gd-ui">Hand over</b></td><td>Give it to someone else on the team.</td></tr><tr><td><b class="gd-ui">Add a note</b></td><td>Leave a note for whoever looks next.</td></tr></tbody></table></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Work oldest due first. A task meets its target when it is done by its due time; that is what your scorecard counts.</div></aside></section><section class="gd-task" id="your-workday-today" data-gd-task><h2 class="gd-h2">Today</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Today lists pickups and returns, and what is due, for your function.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press a booking number to open it. <b class="gd-ui">To do</b> takes you back to your tasks.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/today</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/700"><img src="/guides/img/va-cs-02-today-desktop-dfd277b7.jpg" alt="" loading="lazy" decoding="async" width="1440" height="700"><span class="gd-pin" style="left:20.8%;top:14.3%" aria-hidden="true">1</span></div></div></figure></div></section><section class="gd-task" id="your-workday-documents-to-sign" data-gd-task><h2 class="gd-h2">Documents to sign</h2><p class="gd-p">Your staff agreement, when CarmaCars sends it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The queue shows &quot;You have a document to sign&quot;. Press <b class="gd-ui">Read and sign</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Check the key values at the top (your role, hours, rate and start date), then press <b class="gd-ui">Read the PDF</b> and read it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Sign</b>. Your full legal name is your signature (or press <b class="gd-ui">Draw instead</b>). Several documents? One signature covers all of them. The signed copy stays on the same page.</div></li></ol></div></section><section class="gd-task" id="your-workday-several-functions-switch-with-working-as" data-gd-task><h2 class="gd-h2">Several functions? Switch with Working as</h2><p class="gd-p">If you cover more than one function, <b class="gd-ui">Working as</b> above the menu lists them: Customer service, Finance, Fleet and Sales. Choose one; the menu, To do and Today change to that function.</p></section><section class="gd-task" id="your-workday-your-scorecard" data-gd-task><h2 class="gd-h2">Your scorecard</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">My work</b> &gt; <b class="gd-ui">My scorecard</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">By week shows each measure, its target and your result for each week.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A task meets its target when done by its due time. Daily checks count when done by 9:00 and 18:00.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The first reply target is 5 minutes: a new booking request, an enquiry, a change the renter asked for or a renter message is due 5 minutes after it comes in. An Admin sets it in Program settings, and the target column shows the one in force.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/scorecard</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/360"><img src="/guides/img/va-sales-05-scorecard-desktop-78ec1b03.jpg" alt="" loading="lazy" decoding="async" width="1440" height="360"><span class="gd-pin" style="left:4.2%;top:39.7%" aria-hidden="true">1</span><span class="gd-pin" style="left:62.5%;top:58.3%" aria-hidden="true">2</span></div></div></figure></div></section>');
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

## A buyer lead from a /buy page

Every vehicle page has a for-sale twin (carmacars.ca/buy/toyota/rav4/2023/xle) with "Find me this car", and twins for financing, detailing and body shop work with their own request: a name, an email or phone, and when.

1. The lead is in **Leads**, Buyer leads (kind buyer, finance, detailing or body shop), with the car and what they asked, and a To do line for Sales: A buyer asked us to find a car, Someone asked about financing or leasing a car, A detailing request, or A body shop request.
2. If one of our cars of that kind is for sale (an Admin flags it with its price), offer it. If not, offer to rent them the car for a week first, and say what we can find. We do not lend or lease: on a financing question, say so and offer the rental. For detailing or body shop work, give a time and a price, and always offer a rental while their car is in (an insurance replacement rental when it is a claim).
3. Press **Take it**, then **Update** as you go: contacted, qualified, converted or closed with the reason.

> Tip: We mostly rent cars. Never say a car is for sale unless an Admin flagged it; the page shows it with its price when one is.

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
2. The car: type the VIN. The car is looked up at once and shown in one line with the year, make, model, trim and details (Edit if something is wrong). No VIN at hand: add it by its plate and choose the year, make and model. Tap the colour and check the class. Upload the ownership permit, the insurance slip and the lender''s information if you have them. Photos are optional.
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

## Check renter documents

The renter''s licence photos, selfie and proof of coverage, before the handover.

1. Open the task "identity documents or coverage proof to review", or open the booking: **Review** shows the documents of any booking being arranged or under way, with no task needed.
2. Tick every check under a document, then press **Approve**. Or type the reason the renter reads and press **Reject**.
3. The coverage: OPCF 27 shows the insurer, policy number and expiry; credit card coverage shows the card, its type and whether the name matches. Approve or reject it as a whole.

> Tip: Each opening is logged. An Admin can do the same from Admin > To do.

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
  '<p class="gd-p">You answer requests with offers, quote callers, reply to renters, look renters up, and review owner forms. You are often the renter&#39;s first person.</p><p class="gd-p">Your rail: Queue, Today, Requests, New quote, Renter messages, Find a renter, Calendar, Listings, Similar cars, Owners and enquiries, Owner forms and Scorecard.</p><section class="gd-task" id="customer-service-answer-a-request" data-gd-task><h2 class="gd-h2">Answer a request</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Requests</b>. Filter by New, Waiting on the renter, Pushed back, Offer out or Offer expired.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Waiting shows how long the renter has waited. Open the booking number.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/requests</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/640"><img src="/guides/img/va-cs-03-requests-desktop-b3c66d25.jpg" alt="" loading="lazy" decoding="async" width="1440" height="640"><span class="gd-pin" style="left:27.1%;top:17.5%" aria-hidden="true">1</span><span class="gd-pin" style="left:52.8%;top:32.8%" aria-hidden="true">2</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="3"><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">On the Review tab, check the request: the car is free, the renter, the places.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Adjust the booking</b> to change the car, dates, places, price or extras, then <b class="gd-ui">Save changes</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Add a message and press <b class="gd-ui">Send the offer</b>. Within your limit you can also use <b class="gd-ui">Approve (within my limit)</b> or <b class="gd-ui">Approve and send the pay link</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Can&#39;t do it? <b class="gd-ui">Decline</b> with Reason and any alternative. Need to know more? <b class="gd-ui">Ask the renter</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/bookings/CC-10056?tab=review</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1000"><img src="/guides/img/va-cs-04-booking-review-desktop-52c68a73.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1000"><span class="gd-pin" style="left:69.4%;top:24%" aria-hidden="true">3</span><span class="gd-pin" style="left:95.8%;top:98%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Reply within 5 minutes: send the offer, or ask the renter what you need. That is the &quot;First reply in opening hours&quot; measure on your scorecard. Requests waiting longer show in red.</div></aside></section><section class="gd-task" id="customer-service-an-enquiry-on-an-example-car" data-gd-task><h2 class="gd-h2">An enquiry on an example car</h2><p class="gd-p">Some cars on the site are marked &quot;Example car&quot;: samples that show the kind of cars we rent. A request on one is an enquiry, never a booking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The task Suggest a similar real car comes to To do with the enquiry number (EQ-1001 and up), the car asked for, the dates and the contact.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Find a real car of the same kind and price that is free for those dates, and make a <b class="gd-ui">New quote</b> for it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Call or email the person with the car and the price, then mark the task done.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Reply within the first reply target, as for any request. Never offer the example car itself: it does not exist.</div></aside></section><section class="gd-task" id="customer-service-a-request-from-a-vehicle-page" data-gd-task><h2 class="gd-h2">A request from a vehicle page</h2><p class="gd-p">Every make, model, year and trim page (carmacars.ca/cars/toyota/rav4/2023/xle, for example) has Request it, for the exact car the person wants.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The request arrives as an enquiry with the car named in the message (&quot;About the car: 2023 Toyota RAV4 XLE&quot;) and an Enquiry task in To do.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">If we have that car, or one close to it, free for their dates, make a <b class="gd-ui">New quote</b> for it. If not, suggest the nearest car of the same kind and price.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Reply by email or phone, then mark the task done.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The pages say only what the data says: EPA fuel use, the Canadian trims and our own cars. Never promise equipment the page does not list.</div></aside></section><section class="gd-task" id="customer-service-a-buyer-lead-from-a-buy-page" data-gd-task><h2 class="gd-h2">A buyer lead from a /buy page</h2><p class="gd-p">Every vehicle page has a for-sale twin (carmacars.ca/buy/toyota/rav4/2023/xle) with &quot;Find me this car&quot;, and twins for financing, detailing and body shop work with their own request: a name, an email or phone, and when.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The lead is in <b class="gd-ui">Leads</b>, Buyer leads (kind buyer, finance, detailing or body shop), with the car and what they asked, and a To do line for Sales: A buyer asked us to find a car, Someone asked about financing or leasing a car, A detailing request, or A body shop request.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">If one of our cars of that kind is for sale (an Admin flags it with its price), offer it. If not, offer to rent them the car for a week first, and say what we can find. We do not lend or lease: on a financing question, say so and offer the rental. For detailing or body shop work, give a time and a price, and always offer a rental while their car is in (an insurance replacement rental when it is a claim).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Take it</b>, then <b class="gd-ui">Update</b> as you go: contacted, qualified, converted or closed with the reason.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>We mostly rent cars. Never say a car is for sale unless an Admin flagged it; the page shows it with its price when one is.</div></aside></section><section class="gd-task" id="customer-service-new-quote-for-a-caller" data-gd-task><h2 class="gd-h2">New quote for a caller</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">New quote</b>. Choose the Car, the Pickup and Return (at least 2 hours from now).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose how the lead came in, then the caller&#39;s Full legal name, Email, Mobile and Date of birth.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Set the Licence class and Damage cover, and note places, extras and what they asked.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Create the request</b>. It opens like any request; send the offer from there.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/quotes/new</span></div><div class="gd-imgwrap" style="aspect-ratio:1220/1260"><img src="/guides/img/va-cs-05-new-quote-desktop-4e386b1c.jpg" alt="" loading="lazy" decoding="async" width="1220" height="1260"><span class="gd-pin" style="left:72.1%;top:15.6%" aria-hidden="true">1</span><span class="gd-pin" style="left:72.1%;top:41.7%" aria-hidden="true">2</span><span class="gd-pin" style="left:72.1%;top:72.7%" aria-hidden="true">3</span><span class="gd-pin" style="left:63.9%;top:85.5%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="customer-service-renter-messages-and-find-a-renter" data-gd-task><h2 class="gd-h2">Renter messages and Find a renter</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Renter messages</b> lists the latest messages with their booking. Open the booking to reply, then press <b class="gd-ui">Send</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Find a renter</b>: search by name, email, phone or booking number.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">To open a renter&#39;s private details, press <b class="gd-ui">Open with a reason</b>. The reason is kept in the access log.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/messages</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/260"><img src="/guides/img/va-cs-06-messages-desktop-3441fa91.jpg" alt="" loading="lazy" decoding="async" width="1440" height="260"><span class="gd-pin" style="left:32.6%;top:48.5%" aria-hidden="true">1</span></div></div></figure></div></section><section class="gd-task" id="customer-service-add-a-car-for-an-owner" data-gd-task><h2 class="gd-h2">Add a car for an owner</h2><p class="gd-p">Open <b class="gd-ui">Owners</b> &gt; <b class="gd-ui">Add a car for an owner</b> (fleet: under Cars). You enter everything for the owner; they never fill in the application.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The owner: find them by name, email or phone, or choose New owner and enter the name, email, phone and address.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The car: type the VIN. The car is looked up at once and shown in one line with the year, make, model, trim and details (Edit if something is wrong). No VIN at hand: add it by its plate and choose the year, make and model. Tap the colour and check the class. Upload the ownership permit, the insurance slip and the lender&#39;s information if you have them. Photos are optional.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Terms and first invoice: what was agreed with the owner, to the cent. An Admin checks them before anything is sent.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Who sourced the owner: Entered for CarmaCars, or I sourced this owner. How the owner signs: by email, or on paper.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press <b class="gd-ui">Add the car and send to an Admin</b>. The application waits in the Admin&#39;s Applications, marked Entered by staff with your name. When the Admin approves, the owner gets one email to review and sign.</div></li></ol></div></section><section class="gd-task" id="customer-service-owner-forms-forms-c-and-d" data-gd-task><h2 class="gd-h2">Owner forms (Forms C and D)</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Owner forms</b>. Each row is a scan an owner uploaded, with the witnesses and the status.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press Open to read the scan. Check every page is there and signed, with each witness&#39;s signature and name.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Approve</b>, or <b class="gd-ui">Send back</b> with What to fix (the owner reads this).</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/owner-forms</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/300"><img src="/guides/img/va-cs-08-owner-forms-desktop-eceaee0b.jpg" alt="" loading="lazy" decoding="async" width="1440" height="300"><span class="gd-pin" style="left:68.6%;top:36.7%" aria-hidden="true">2</span><span class="gd-pin" style="left:76.7%;top:36.7%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="customer-service-a-rental-agreement-signed-on-paper" data-gd-task><h2 class="gd-h2">A rental agreement signed on paper</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the booking. Under Signed on paper, press <b class="gd-ui">Record paper signature</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose the Rental agreement, or the booking change the renter signed.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Check Signed by and Date signed, and upload the scan of every signed page.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Record signature</b>. It counts as signed, and the renter is not asked to sign again.</div></li></ol></div></section><section class="gd-task" id="customer-service-check-renter-documents" data-gd-task><h2 class="gd-h2">Check renter documents</h2><p class="gd-p">The renter&#39;s licence photos, selfie and proof of coverage, before the handover.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the task &quot;identity documents or coverage proof to review&quot;, or open the booking: <b class="gd-ui">Review</b> shows the documents of any booking being arranged or under way, with no task needed.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Tick every check under a document, then press <b class="gd-ui">Approve</b>. Or type the reason the renter reads and press <b class="gd-ui">Reject</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The coverage: OPCF 27 shows the insurer, policy number and expiry; credit card coverage shows the card, its type and whether the name matches. Approve or reject it as a whole.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Each opening is logged. An Admin can do the same from Admin &gt; To do.</div></aside></section><section class="gd-task" id="customer-service-a-change-to-a-confirmed-booking" data-gd-task><h2 class="gd-h2">A change to a confirmed booking</h2><p class="gd-p">On a booking&#39;s Changes tab you can propose new dates, times or another car, as an Admin does: set the change, write the reason, press <b class="gd-ui">Preview the price</b>, then <b class="gd-ui">Send to the renter</b>. The renter has 48 hours to accept and sign the amendment. You also send a new signing link to an additional driver from the booking screen.</p></section><section class="gd-task" id="customer-service-a-late-return" data-gd-task><h2 class="gd-h2">A late return</h2><p class="gd-p">A booking past its return time shows the late return panel. Work it in order:</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Button</th><th scope="col">When</th></tr></thead><tbody><tr><td><b class="gd-ui">Log a call</b></td><td>Record each call to the renter and what they said.</td></tr><tr><td><b class="gd-ui">Send T13</b></td><td>The first late notice email.</td></tr><tr><td><b class="gd-ui">Send T14 (final notice)</b></td><td>The final notice.</td></tr><tr><td><b class="gd-ui">Request disable</b></td><td>Ask an Admin to approve disabling the car.</td></tr><tr><td><b class="gd-ui">Open an incident</b></td><td>When the car is not coming back as planned.</td></tr></tbody></table></div></section>');
select app.guide_release_section('va', 'finance', 'chapter', 'customer-service', 'You keep the money right: payments, deposits and refunds, toll notices, processor payouts and Turo trips.

Your rail: Queue, Today, Payments, deposits, refunds, Tolls and tickets, Reconciliation, Turo trips, Find a renter, Calendar and Scorecard.

## Your queue

Finance tasks include failed owner debits, toll notices with no match, statements to review and refunds to issue.

![The type filters show what Finance handles: collect upfront, debit failed, match toll, refund cancellation and review statements.](/guides/img/va-finance-01-queue-desktop-295e545d.jpg "desktop; size: 1440 560; address: carmacars.ca/va; pins: 1 26.4 45.4")

## Payments, deposits, refunds

1. Failed payments: each with the purpose, amount and the bank''s reason.
2. Deposits to take before pickup, and deposits due back.
3. Refunds in progress. Press **Request the refund**; above your limit it waits for an Admin. Then **Issue the refund**.
4. Owner invoices that failed, and owner statements to prepare.

![](/guides/img/va-finance-02-money-desktop-70fea0c7.jpg "desktop; size: 1230 1060; address: carmacars.ca/va/money; pins: 1 10.6 6.6, 2 12.2 19.2, 3 10.6 57.3, 4 13.0 73.2")

## A payment received another way

An owner or renter paid by e-Transfer, cheque, cash or bank transfer.

1. Owner invoice: on **Payments, deposits, refunds**, find it under Owner invoices owing and press **Record payment**.
2. Renter: beside the failed payment, press **Paid another way**. Or open the booking''s Money tab and press **Record a payment received another way**.
3. Choose Paid by, the Date received and the Reference (the cheque number for a cheque). Leave Amount empty for the full balance; type less for a partial payment.
4. Add the proof if you have it (a screenshot or a photo of the cheque), then press **Record payment**.

The invoice is marked paid or partly paid, the automatic debit stops for that amount and the owner gets a receipt. Above your single limit the payment needs an Admin. Recorded something wrong? Ask an Admin to void it; you cannot void a payment.

Each month''s payments recorded by hand are listed under Reconciliation, with the totals by method, to check against the bank.

## Read a toll notice

1. Open **Tolls and tickets** and press **Read a notice**.
2. Choose the file: a PDF, a photo or a CSV, under 15 MB. Leave the reading profile to find it from the text.
3. Press **Read it**. Then check each line beside the notice and fix what was read wrong.
4. Press **Checked against the notice** on each line (**Leave out** to skip one), then **Save as checked** and **Confirm and import**.

![](/guides/img/va-finance-04-tolls-read-desktop-aa04a6b2.jpg "desktop; size: 1230 580; address: carmacars.ca/va/tolls/read; pins: 2 19.5 44.1, 3 4.1 64.8, 4 4.1 89.7")

> Tip: In the work queue, **Match again** retries the match after a fix, and **Dispute** marks a notice you think is wrong. Renters matched with high confidence are charged at import, with the notice and our fee.

![The work queue: Unmatched, Needs review, Matched not charged and Disputed, with each notice''s plate, date, amount and match.](/guides/img/va-finance-03-tolls-desktop-37b6f99c.jpg "desktop; size: 1230 540; address: carmacars.ca/va/tolls; pins: 1 23.6 12.2")

## Reconciliation and Turo trips

1. **Reconciliation**: press **Record a processor payout**, then **Match** it to the payments it contains. Anything still unmatched at the closing check goes to an Admin.
2. **Turo trips**: press **Add a trip** for one trip, or paste CSV rows and press **Import**.

![](/guides/img/va-finance-06-turo-desktop-b59cc7f9.jpg "desktop; size: 1230 540; address: carmacars.ca/va/turo; pins: 2 95.1 14.8")
', 'Finance', 'Payments, deposits and refunds, tolls and tickets, reconciliation and Turo trips.',
  'You keep the money right: payments, deposits and refunds, toll notices, processor payouts and Turo trips.

Your rail: Queue, Today, Payments, deposits, refunds, Tolls and tickets, Reconciliation, Turo trips, Find a renter, Calendar and Scorecard.

## Your queue

Finance tasks include failed owner debits, toll notices with no match, statements to review and refunds to issue.

![The type filters show what Finance handles: collect upfront, debit failed, match toll, refund cancellation and review statements.](/guides/img/va-finance-01-queue-desktop-295e545d.jpg "desktop; size: 1440 560; address: carmacars.ca/va; pins: 1 26.4 45.4")

## Payments, deposits, refunds

1. Failed payments: each with the purpose, amount and the bank''s reason.
2. Deposits to take before pickup, and deposits due back.
3. Refunds in progress. Press **Request the refund** and choose What it refunds (the rental charge, delivery or pickup, kilometres, add-ons or other charges); above your limit it waits for an Admin. Then **Issue the refund**.
4. Owner invoices that failed, and owner statements to prepare.

![](/guides/img/va-finance-02-money-desktop-70fea0c7.jpg "desktop; size: 1230 1060; address: carmacars.ca/va/money; pins: 1 10.6 6.6, 2 12.2 19.2, 3 10.6 57.3, 4 13.0 73.2")

## A payment received another way

An owner or renter paid by e-Transfer, cheque, cash or bank transfer.

1. Owner invoice: on **Payments, deposits, refunds**, find it under Owner invoices owing and press **Record payment**.
2. Renter: beside the failed payment, press **Paid another way**. Or open the booking''s Money tab and press **Record a payment received another way**.
3. Choose Paid by, the Date received and the Reference (the cheque number for a cheque). Leave Amount empty for the full balance; type less for a partial payment.
4. Add the proof if you have it (a screenshot or a photo of the cheque), then press **Record payment**.

The invoice is marked paid or partly paid, the automatic debit stops for that amount and the owner gets a receipt. Above your single limit the payment needs an Admin. Recorded something wrong? Ask an Admin to void it; you cannot void a payment.

Each month''s payments recorded by hand are listed under Reconciliation, with the totals by method, to check against the bank.

## Read a toll notice

1. Open **Tolls and tickets** and press **Read a notice**.
2. Choose the file: a PDF, a photo or a CSV, under 15 MB. Leave the reading profile to find it from the text.
3. Press **Read it**. Then check each line beside the notice and fix what was read wrong.
4. Press **Checked against the notice** on each line (**Leave out** to skip one), then **Save as checked** and **Confirm and import**.

![](/guides/img/va-finance-04-tolls-read-desktop-aa04a6b2.jpg "desktop; size: 1230 580; address: carmacars.ca/va/tolls/read; pins: 2 19.5 44.1, 3 4.1 64.8, 4 4.1 89.7")

> Tip: In the work queue, **Match again** retries the match after a fix, and **Dispute** marks a notice you think is wrong. Renters matched with high confidence are charged at import, with the notice and our fee.

![The work queue: Unmatched, Needs review, Matched not charged and Disputed, with each notice''s plate, date, amount and match.](/guides/img/va-finance-03-tolls-desktop-37b6f99c.jpg "desktop; size: 1230 540; address: carmacars.ca/va/tolls; pins: 1 23.6 12.2")

## Reconciliation and Turo trips

1. **Reconciliation**: press **Record a processor payout**, then **Match** it to the payments it contains. Anything still unmatched at the closing check goes to an Admin.
2. **Turo trips**: press **Add a trip** for one trip, or paste CSV rows and press **Import**.

![](/guides/img/va-finance-06-turo-desktop-b59cc7f9.jpg "desktop; size: 1230 540; address: carmacars.ca/va/turo; pins: 2 95.1 14.8")
',
  '<p class="gd-p">You keep the money right: payments, deposits and refunds, toll notices, processor payouts and Turo trips.</p><p class="gd-p">Your rail: Queue, Today, Payments, deposits, refunds, Tolls and tickets, Reconciliation, Turo trips, Find a renter, Calendar and Scorecard.</p><section class="gd-task" id="finance-your-queue" data-gd-task><h2 class="gd-h2">Your queue</h2><p class="gd-p">Finance tasks include failed owner debits, toll notices with no match, statements to review and refunds to issue.</p><div class="gd-figblock"><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/560"><img src="/guides/img/va-finance-01-queue-desktop-295e545d.jpg" alt="The type filters show what Finance handles: collect upfront, debit failed, match toll, refund cancellation and review statements." loading="lazy" decoding="async" width="1440" height="560"><span class="gd-pin" style="left:26.4%;top:45.4%" aria-hidden="true">1</span></div></div><figcaption>The type filters show what Finance handles: collect upfront, debit failed, match toll, refund cancellation and review statements.</figcaption></figure></div></section><section class="gd-task" id="finance-payments-deposits-refunds" data-gd-task><h2 class="gd-h2">Payments, deposits, refunds</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Failed payments: each with the purpose, amount and the bank&#39;s reason.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Deposits to take before pickup, and deposits due back.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Refunds in progress. Press <b class="gd-ui">Request the refund</b> and choose What it refunds (the rental charge, delivery or pickup, kilometres, add-ons or other charges); above your limit it waits for an Admin. Then <b class="gd-ui">Issue the refund</b>.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Owner invoices that failed, and owner statements to prepare.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/money</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/1060"><img src="/guides/img/va-finance-02-money-desktop-70fea0c7.jpg" alt="" loading="lazy" decoding="async" width="1230" height="1060"><span class="gd-pin" style="left:10.6%;top:6.6%" aria-hidden="true">1</span><span class="gd-pin" style="left:12.2%;top:19.2%" aria-hidden="true">2</span><span class="gd-pin" style="left:10.6%;top:57.3%" aria-hidden="true">3</span><span class="gd-pin" style="left:13%;top:73.2%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="finance-a-payment-received-another-way" data-gd-task><h2 class="gd-h2">A payment received another way</h2><p class="gd-p">An owner or renter paid by e-Transfer, cheque, cash or bank transfer.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Owner invoice: on <b class="gd-ui">Payments, deposits, refunds</b>, find it under Owner invoices owing and press <b class="gd-ui">Record payment</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Renter: beside the failed payment, press <b class="gd-ui">Paid another way</b>. Or open the booking&#39;s Money tab and press <b class="gd-ui">Record a payment received another way</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Choose Paid by, the Date received and the Reference (the cheque number for a cheque). Leave Amount empty for the full balance; type less for a partial payment.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Add the proof if you have it (a screenshot or a photo of the cheque), then press <b class="gd-ui">Record payment</b>.</div></li></ol></div><p class="gd-p">The invoice is marked paid or partly paid, the automatic debit stops for that amount and the owner gets a receipt. Above your single limit the payment needs an Admin. Recorded something wrong? Ask an Admin to void it; you cannot void a payment.</p><p class="gd-p">Each month&#39;s payments recorded by hand are listed under Reconciliation, with the totals by method, to check against the bank.</p></section><section class="gd-task" id="finance-read-a-toll-notice" data-gd-task><h2 class="gd-h2">Read a toll notice</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Tolls and tickets</b> and press <b class="gd-ui">Read a notice</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose the file: a PDF, a photo or a CSV, under 15 MB. Leave the reading profile to find it from the text.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Read it</b>. Then check each line beside the notice and fix what was read wrong.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Checked against the notice</b> on each line (<b class="gd-ui">Leave out</b> to skip one), then <b class="gd-ui">Save as checked</b> and <b class="gd-ui">Confirm and import</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/tolls/read</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/580"><img src="/guides/img/va-finance-04-tolls-read-desktop-aa04a6b2.jpg" alt="" loading="lazy" decoding="async" width="1230" height="580"><span class="gd-pin" style="left:19.5%;top:44.1%" aria-hidden="true">2</span><span class="gd-pin" style="left:4.1%;top:64.8%" aria-hidden="true">3</span><span class="gd-pin" style="left:4.1%;top:89.7%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>In the work queue, <b class="gd-ui">Match again</b> retries the match after a fix, and <b class="gd-ui">Dispute</b> marks a notice you think is wrong. Renters matched with high confidence are charged at import, with the notice and our fee.</div></aside><div class="gd-figblock"><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/tolls</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/540"><img src="/guides/img/va-finance-03-tolls-desktop-37b6f99c.jpg" alt="The work queue: Unmatched, Needs review, Matched not charged and Disputed, with each notice&#39;s plate, date, amount and match." loading="lazy" decoding="async" width="1230" height="540"><span class="gd-pin" style="left:23.6%;top:12.2%" aria-hidden="true">1</span></div></div><figcaption>The work queue: Unmatched, Needs review, Matched not charged and Disputed, with each notice&#39;s plate, date, amount and match.</figcaption></figure></div></section><section class="gd-task" id="finance-reconciliation-and-turo-trips" data-gd-task><h2 class="gd-h2">Reconciliation and Turo trips</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Reconciliation</b>: press <b class="gd-ui">Record a processor payout</b>, then <b class="gd-ui">Match</b> it to the payments it contains. Anything still unmatched at the closing check goes to an Admin.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Turo trips</b>: press <b class="gd-ui">Add a trip</b> for one trip, or paste CSV rows and press <b class="gd-ui">Import</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/turo</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/540"><img src="/guides/img/va-finance-06-turo-desktop-b59cc7f9.jpg" alt="" loading="lazy" decoding="async" width="1230" height="540"><span class="gd-pin" style="left:95.1%;top:14.8%" aria-hidden="true">2</span></div></div></figure></div></section>');
select app.guide_release_section('va', 'fleet', 'chapter', 'finance', 'You keep the cars moving: field jobs, daily checks, photo reviews after returns, and the listing pipeline with its duplicate check and plate covering.

Your rail: Queue, Today, Field jobs, Daily checks, Photo reviews, Calendar, Listings, Similar cars, Find a renter and Scorecard.

## Schedule field jobs

1. Handovers and returns without a job are listed first. Every booking needs one.
2. Press **Schedule**: choose the kind, car, when, place, field staff and instructions.
3. Jobs, next three days: each with its field staff and whether they acknowledged it.
4. Change a job with **Assign**, **Reassign**, **Move** or **Cancel**.

![](/guides/img/va-fleet-02-field-jobs-desktop-b985927b.jpg "desktop; size: 1230 1180; address: carmacars.ca/va/fleet; pins: 1 15.4 10.4, 2 78.9 12.7, 3 11.4 68.6, 4 78.9 83.9")

## Daily checks

Twice a day: the opening check by 9:00 and the closing check by 18:00.

1. Open **Daily checks** and choose **Opening check** or **Closing check**.
2. Each line shows what was found. Tick OK, or Problem with a note.
3. Press **Save the opening check** (or **Save the closing check**). You can save it again.

![](/guides/img/va-fleet-03-daily-checks-desktop-be06d6c0.jpg "desktop; size: 1230 820; address: carmacars.ca/va/checks; pins: 1 6.5 15.4, 2 44.7 42.0, 3 64.2 94.0")

## Photo reviews after a return

After each return, the field photo set waits under **Photo reviews**. Compare it with the pickup set. Press **Review done**, or **Ask for a re-shoot** if a photo is missing or unclear.

## Similar cars

A possible duplicate listing stops publishing until you decide.

1. Each flag shows the car, what it looks like (same VIN, plate, photo or specs) and the other car.
2. Compare the permit, the plate and the photos.
3. Press **Not a duplicate** with a note when they are different cars, or **Same car** when they are.

![](/guides/img/va-fleet-06-similar-cars-desktop-562b0382.jpg "desktop; size: 1230 460; address: carmacars.ca/va/similar-cars; pins: 1 23.6 30.4, 3 94.8 30.4")

## Rates and kilometres

From a listing, press **The car and its rates**, or open the car from Field jobs.

1. Type the rates an Admin set. Only the daily rate is needed; the others follow from it when empty. The weekend rate is a price per day for each day that starts on a Friday or Saturday.
2. Keep **Use the defaults** for the kilometres, or choose **Custom for this car**.
3. Check What renters pay under the fields, then press **Save the rates**. Rates, kilometres and deposit save together.

## Listings and covering plates

1. Open **Listings**. A draft waiting shows Needs review. Open it.
2. The copy is written by itself (change a line only if you must: it is then kept). Check the photos: on each public photo, cover the plate or mark it not visible.

![](/guides/img/va-fleet-05-listings-desktop-d2672e0a.jpg "desktop; size: 1230 340; address: carmacars.ca/va/listings; pins: 1 54.5 49.1")

3. Press **Cover the plate**. Check the suggested box; **Suggest the plate** asks again.
4. Drag over a plate to draw a box; drag a box to move it, its corner to resize it.
5. Choose **A CarmaCars plate**, **Pixelation** or **Blur**, then **Save the covered photo**.
6. No plate in the shot? **No plate visible on this photo**.

![](/guides/img/admin-11-plate-editor-phone-95d5afd2.jpg "phone; size: 390 776; pins: 3 52.6 78.9, 4 50.0 43.8, 5 61.5 62.1, 6 43.1 92.3")

> Watch out: Publishing waits until every public photo is covered or marked. The covered photo replaces the public one; the original is kept privately.

## Calendar sync with Turo and other platforms

**Cars** > **Calendar sync**: a car listed on Turo or Getaround must never be booked twice.

1. Turo has no calendar link: Turo''s trip emails come in by themselves and block the car with the turnaround. For each car on Turo, press **This car is on Turo**, type its name exactly as Turo''s emails show it and press **Save**.
2. Under "Turo emails to check", an email the reader was not sure about: check the trip on Turo, then **Add as a Turo trip** (choose the car, check the dates) or **Dismiss**. A trip whose email did not come: **Add a Turo trip** on the car.
3. Turo cannot read our calendar: under "Block on Turo", block each CarmaCars booking on the car''s Turo calendar, then press **Done on Turo**. Dates that changed or a booking cancelled here show the dates to free on Turo.
4. Getaround, Google Calendar or another platform with a calendar (iCal) link: open **Add a calendar link**, choose the platform, paste it and press **Add the link**. Copy the car''s CarmaCars link for that platform with **Copy** and paste it into the platform''s calendar import.
5. A double booking raises an urgent task for you and an email: move, swap or cancel one trip. A link that stops working raises a task after 3 failed reads: copy it from the platform again.
', 'Fleet', 'Field jobs, daily checks, photo reviews, similar cars and listings.',
  'You keep the cars moving: field jobs, daily checks, photo reviews after returns, and the listing pipeline with its duplicate check and plate covering.

Your rail: Queue, Today, Field jobs, Daily checks, Photo reviews, Calendar, Listings, Similar cars, Find a renter and Scorecard.

## Schedule field jobs

1. Handovers and returns without a job are listed first. Every booking needs one.
2. Press **Schedule**: choose the kind, car, when, place, field staff and instructions.
3. Jobs, next three days: each with its field staff and whether they acknowledged it.
4. Change a job with **Assign**, **Reassign**, **Move** or **Cancel**.

![](/guides/img/va-fleet-02-field-jobs-desktop-b985927b.jpg "desktop; size: 1230 1180; address: carmacars.ca/va/fleet; pins: 1 15.4 10.4, 2 78.9 12.7, 3 11.4 68.6, 4 78.9 83.9")

## Daily checks

Twice a day: the opening check by 9:00 and the closing check by 18:00.

1. Open **Daily checks** and choose **Opening check** or **Closing check**.
2. Each line shows what was found. Tick OK, or Problem with a note.
3. Press **Save the opening check** (or **Save the closing check**). You can save it again.

![](/guides/img/va-fleet-03-daily-checks-desktop-be06d6c0.jpg "desktop; size: 1230 820; address: carmacars.ca/va/checks; pins: 1 6.5 15.4, 2 44.7 42.0, 3 64.2 94.0")

## Photo reviews after a return

After each return, the field photo set waits under **Photo reviews**. Compare it with the pickup set. Press **Review done**, or **Ask for a re-shoot** if a photo is missing or unclear.

## Similar cars

A possible duplicate never keeps a car off the site: it shows on the car''s checklist until you decide. Only Same car takes it off.

1. Each flag shows the car, what it looks like (same VIN, plate, photo or specs) and the other car.
2. Compare the permit, the plate and the photos.
3. Press **Not a duplicate** with a note when they are different cars, or **Same car** when they are.

![](/guides/img/va-fleet-06-similar-cars-desktop-562b0382.jpg "desktop; size: 1230 460; address: carmacars.ca/va/similar-cars; pins: 1 23.6 30.4, 3 94.8 30.4")

## Rates and kilometres

From a listing, press **The car and its rates**, or open the car from Field jobs.

1. Type the rates an Admin set. Only the daily rate is needed; the others follow from it when empty. The weekend rate is a price per day for each day that starts on a Friday or Saturday.
2. Keep **Use the defaults** for the kilometres, or choose **Custom for this car**.
3. Check What renters pay under the fields, then press **Save the rates**. Rates, kilometres and deposit save together.

## Listings and covering plates

1. Open **Listings**. A draft waiting shows Needs review. Open it.
2. The copy is written by itself (change a line only if you must: it is then kept). Check the photos: on each public photo, cover the plate or mark it not visible.

![](/guides/img/va-fleet-05-listings-desktop-d2672e0a.jpg "desktop; size: 1230 340; address: carmacars.ca/va/listings; pins: 1 54.5 49.1")

3. Press **Cover the plate**. Check the suggested box; **Suggest the plate** asks again.
4. Drag over a plate to draw a box; drag a box to move it, its corner to resize it.
5. Choose **A CarmaCars plate**, **Pixelation** or **Blur**, then **Save the covered photo**.
6. No plate in the shot? **No plate visible on this photo**.

![](/guides/img/admin-11-plate-editor-phone-95d5afd2.jpg "phone; size: 390 776; pins: 3 52.6 78.9, 4 50.0 43.8, 5 61.5 62.1, 6 43.1 92.3")

> Watch out: The plate check never holds a car back: a photo whose plate is not checked stays private, and goes public by itself once it is covered or marked. The covered photo replaces the public one; the original is kept privately.

## Publish now

Customer service and fleet publish a car themselves; nothing has to be finished first.

1. Open the car from Listings or Field jobs. Its listing says why it is not on the site yet; press **Publish now**. With no rates yet it uses the suggested rates (similar cars, else the class defaults).
2. What is still open (paperwork, details, photos, No VIN yet for a car added by its plate, a possible duplicate) shows as warnings after Publish now and on the car. None of them stops publishing.
3. New cars with their rates usually go on the site by themselves (Publish new cars automatically, on by default). A car taken off the site by staff waits for Publish now.

> Tip: A car not on the fleet insurance policy yet can be requested, offered and paid for, but never handed over until the insurer confirms it. Requests and offers for such a car show a warning.

## Calendar sync with Turo and other platforms

**Cars** > **Calendar sync**: a car listed on Turo or Getaround must never be booked twice.

1. Turo has no calendar link: Turo''s trip emails come in by themselves, find their car by themselves (Turo car number, plate, VIN, year, make, model, trim, colour, what earlier emails taught) and block it with the turnaround. Nothing to set up per car.
2. An email the reader cannot place waits as "Which car is this?": press **Which car is this?** and press the right car (best guesses first). It is remembered for that car''s next emails. If the dates or trip number are missing: **Add as a Turo trip** (choose the car, check the dates) or **Dismiss**. A trip whose email did not come: **Add a Turo trip** on the car.
3. Each Turo trip shows the guest''s name and phone when Turo''s email includes them. Contact a Turo guest only about their trip, never with promotions.
4. Turo cannot read our calendar: under "Block on Turo", block each CarmaCars booking on the car''s Turo calendar, then press **Done on Turo**. Dates that changed or a booking cancelled here show the dates to free on Turo.
5. Getaround, Google Calendar or another platform with a calendar (iCal) link: open **Add a calendar link**, choose the platform, paste it and press **Add the link**. Copy the car''s CarmaCars link for that platform with **Copy** and paste it into the platform''s calendar import.
6. A double booking raises an urgent task for you and an email: move, swap or cancel one trip. A link that stops working raises a task after 3 failed reads: copy it from the platform again.
',
  '<p class="gd-p">You keep the cars moving: field jobs, daily checks, photo reviews after returns, and the listing pipeline with its duplicate check and plate covering.</p><p class="gd-p">Your rail: Queue, Today, Field jobs, Daily checks, Photo reviews, Calendar, Listings, Similar cars, Find a renter and Scorecard.</p><section class="gd-task" id="fleet-schedule-field-jobs" data-gd-task><h2 class="gd-h2">Schedule field jobs</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Handovers and returns without a job are listed first. Every booking needs one.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Schedule</b>: choose the kind, car, when, place, field staff and instructions.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Jobs, next three days: each with its field staff and whether they acknowledged it.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Change a job with <b class="gd-ui">Assign</b>, <b class="gd-ui">Reassign</b>, <b class="gd-ui">Move</b> or <b class="gd-ui">Cancel</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/fleet</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/1180"><img src="/guides/img/va-fleet-02-field-jobs-desktop-b985927b.jpg" alt="" loading="lazy" decoding="async" width="1230" height="1180"><span class="gd-pin" style="left:15.4%;top:10.4%" aria-hidden="true">1</span><span class="gd-pin" style="left:78.9%;top:12.7%" aria-hidden="true">2</span><span class="gd-pin" style="left:11.4%;top:68.6%" aria-hidden="true">3</span><span class="gd-pin" style="left:78.9%;top:83.9%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="fleet-daily-checks" data-gd-task><h2 class="gd-h2">Daily checks</h2><p class="gd-p">Twice a day: the opening check by 9:00 and the closing check by 18:00.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Daily checks</b> and choose <b class="gd-ui">Opening check</b> or <b class="gd-ui">Closing check</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each line shows what was found. Tick OK, or Problem with a note.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Save the opening check</b> (or <b class="gd-ui">Save the closing check</b>). You can save it again.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/checks</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/820"><img src="/guides/img/va-fleet-03-daily-checks-desktop-be06d6c0.jpg" alt="" loading="lazy" decoding="async" width="1230" height="820"><span class="gd-pin" style="left:6.5%;top:15.4%" aria-hidden="true">1</span><span class="gd-pin" style="left:44.7%;top:42%" aria-hidden="true">2</span><span class="gd-pin" style="left:64.2%;top:94%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="fleet-photo-reviews-after-a-return" data-gd-task><h2 class="gd-h2">Photo reviews after a return</h2><p class="gd-p">After each return, the field photo set waits under <b class="gd-ui">Photo reviews</b>. Compare it with the pickup set. Press <b class="gd-ui">Review done</b>, or <b class="gd-ui">Ask for a re-shoot</b> if a photo is missing or unclear.</p></section><section class="gd-task" id="fleet-similar-cars" data-gd-task><h2 class="gd-h2">Similar cars</h2><p class="gd-p">A possible duplicate never keeps a car off the site: it shows on the car&#39;s checklist until you decide. Only Same car takes it off.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each flag shows the car, what it looks like (same VIN, plate, photo or specs) and the other car.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Compare the permit, the plate and the photos.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Not a duplicate</b> with a note when they are different cars, or <b class="gd-ui">Same car</b> when they are.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/similar-cars</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/460"><img src="/guides/img/va-fleet-06-similar-cars-desktop-562b0382.jpg" alt="" loading="lazy" decoding="async" width="1230" height="460"><span class="gd-pin" style="left:23.6%;top:30.4%" aria-hidden="true">1</span><span class="gd-pin" style="left:94.8%;top:30.4%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="fleet-rates-and-kilometres" data-gd-task><h2 class="gd-h2">Rates and kilometres</h2><p class="gd-p">From a listing, press <b class="gd-ui">The car and its rates</b>, or open the car from Field jobs.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Type the rates an Admin set. Only the daily rate is needed; the others follow from it when empty. The weekend rate is a price per day for each day that starts on a Friday or Saturday.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Keep <b class="gd-ui">Use the defaults</b> for the kilometres, or choose <b class="gd-ui">Custom for this car</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Check What renters pay under the fields, then press <b class="gd-ui">Save the rates</b>. Rates, kilometres and deposit save together.</div></li></ol></div></section><section class="gd-task" id="fleet-listings-and-covering-plates" data-gd-task><h2 class="gd-h2">Listings and covering plates</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Listings</b>. A draft waiting shows Needs review. Open it.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The copy is written by itself (change a line only if you must: it is then kept). Check the photos: on each public photo, cover the plate or mark it not visible.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/listings</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/340"><img src="/guides/img/va-fleet-05-listings-desktop-d2672e0a.jpg" alt="" loading="lazy" decoding="async" width="1230" height="340"><span class="gd-pin" style="left:54.5%;top:49.1%" aria-hidden="true">1</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol" start="3"><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Cover the plate</b>. Check the suggested box; <b class="gd-ui">Suggest the plate</b> asks again.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Drag over a plate to draw a box; drag a box to move it, its corner to resize it.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Choose <b class="gd-ui">A CarmaCars plate</b>, <b class="gd-ui">Pixelation</b> or <b class="gd-ui">Blur</b>, then <b class="gd-ui">Save the covered photo</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">No plate in the shot? <b class="gd-ui">No plate visible on this photo</b>.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/776"><img src="/guides/img/admin-11-plate-editor-phone-95d5afd2.jpg" alt="" loading="lazy" decoding="async" width="390" height="776"><span class="gd-pin" style="left:52.6%;top:78.9%" aria-hidden="true">3</span><span class="gd-pin" style="left:50%;top:43.8%" aria-hidden="true">4</span><span class="gd-pin" style="left:61.5%;top:62.1%" aria-hidden="true">5</span><span class="gd-pin" style="left:43.1%;top:92.3%" aria-hidden="true">6</span></div></div></figure></div><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>The plate check never holds a car back: a photo whose plate is not checked stays private, and goes public by itself once it is covered or marked. The covered photo replaces the public one; the original is kept privately.</div></aside></section><section class="gd-task" id="fleet-publish-now" data-gd-task><h2 class="gd-h2">Publish now</h2><p class="gd-p">Customer service and fleet publish a car themselves; nothing has to be finished first.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the car from Listings or Field jobs. Its listing says why it is not on the site yet; press <b class="gd-ui">Publish now</b>. With no rates yet it uses the suggested rates (similar cars, else the class defaults).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">What is still open (paperwork, details, photos, No VIN yet for a car added by its plate, a possible duplicate) shows as warnings after Publish now and on the car. None of them stops publishing.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">New cars with their rates usually go on the site by themselves (Publish new cars automatically, on by default). A car taken off the site by staff waits for Publish now.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A car not on the fleet insurance policy yet can be requested, offered and paid for, but never handed over until the insurer confirms it. Requests and offers for such a car show a warning.</div></aside></section><section class="gd-task" id="fleet-calendar-sync-with-turo-and-other-platforms" data-gd-task><h2 class="gd-h2">Calendar sync with Turo and other platforms</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Calendar sync</b>: a car listed on Turo or Getaround must never be booked twice.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Turo has no calendar link: Turo&#39;s trip emails come in by themselves, find their car by themselves (Turo car number, plate, VIN, year, make, model, trim, colour, what earlier emails taught) and block it with the turnaround. Nothing to set up per car.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">An email the reader cannot place waits as &quot;Which car is this?&quot;: press <b class="gd-ui">Which car is this?</b> and press the right car (best guesses first). It is remembered for that car&#39;s next emails. If the dates or trip number are missing: <b class="gd-ui">Add as a Turo trip</b> (choose the car, check the dates) or <b class="gd-ui">Dismiss</b>. A trip whose email did not come: <b class="gd-ui">Add a Turo trip</b> on the car.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Each Turo trip shows the guest&#39;s name and phone when Turo&#39;s email includes them. Contact a Turo guest only about their trip, never with promotions.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Turo cannot read our calendar: under &quot;Block on Turo&quot;, block each CarmaCars booking on the car&#39;s Turo calendar, then press <b class="gd-ui">Done on Turo</b>. Dates that changed or a booking cancelled here show the dates to free on Turo.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Getaround, Google Calendar or another platform with a calendar (iCal) link: open <b class="gd-ui">Add a calendar link</b>, choose the platform, paste it and press <b class="gd-ui">Add the link</b>. Copy the car&#39;s CarmaCars link for that platform with <b class="gd-ui">Copy</b> and paste it into the platform&#39;s calendar import.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">A double booking raises an urgent task for you and an email: move, swap or cancel one trip. A link that stops working raises a task after 3 failed reads: copy it from the platform again.</div></li></ol></div></section>');
select app.guide_release_section('va', 'commissions', 'chapter', 'add-a-rental-by-hand', 'Every function earns a commission on the rentals it sources: a renter you found yourself. Say so when you enter the rental, the quote or the offer.

## Mark who found the client

Every rental, quote and offer you enter asks: **I sourced this client** or **Entered for CarmaCars**.

1. Choose **I sourced this client** when you found the renter yourself: someone you know, your own post or your own outreach.
2. Choose **Entered for CarmaCars** when the renter came to CarmaCars: the website, the phone line, a walk-in, a partner.
3. A website request earns nothing by itself. If you sourced it anyway, choose I sourced this client on its offer: an Admin decides.

|  | Commission |
| --- | --- |
| Sales | Commission only, with no base pay and no set hours. By the rental days of the month: under 50 days 10%, from 50 days 15%, from 100 days 20%, on all of that month''s rentals |
| Customer service, finance, fleet | 10% |
| How much | The rate on the rental charge before tax, after discounts, less refunds |
| When earned | When the rental is completed and paid in full. Never on a cancelled, refunded, unpaid or charged-back rental, or on your own or a household rental |
| Your home address | It must be in your profile. Until it is, a commission waits as not earned yet, and you cannot add a rental or mark I sourced this client |
| Paid | After an Admin approves it, by transfer or on your pay statement. My sales shows each step: not earned yet, pending approval, approved, paid, reversed |

> Tip: A refund or chargeback after a commission was paid comes off your next payment. Your staff agreement has the full rule.
', 'Commissions', 'I sourced this client, your rate, when it is earned, approved and paid.',
  'Every function earns a commission on the rentals it sources: a renter you found yourself. Say so when you enter the rental, the quote or the offer.

## Mark who found the client

Every rental, quote and offer you enter asks: **I sourced this client** or **Entered for CarmaCars**.

1. Choose **I sourced this client** when you found the renter yourself: someone you know, your own post or your own outreach.
2. Choose **Entered for CarmaCars** when the renter came to CarmaCars: the website, the phone line, a walk-in, a partner.
3. A website request earns nothing by itself. If you sourced it anyway, choose I sourced this client on its offer: an Admin decides.

|  | Commission |
| --- | --- |
| Sales | Commission only, with no base pay and no set hours. By the rental days of the month: under 50 days 10%, from 50 days 15%, from 100 days 20%, on all of that month''s rentals |
| Customer service, finance, fleet | 10% |
| How much | The rate on the rental charge before tax, after discounts, with late extra days; never on delivery, kilometres, add-ons or anything else bought. Only a refund of the rental charge comes off |
| When earned | When the rental is completed and paid in full. Never on a cancelled, refunded, unpaid or charged-back rental, or on your own or a household rental |
| Your home address | It must be in your profile. Until it is, a commission waits as not earned yet, and you cannot add a rental or mark I sourced this client |
| Paid | After an Admin approves it, by transfer or on your pay statement. My sales shows each step: not earned yet, pending approval, approved, paid, reversed |

> Tip: A refund or chargeback after a commission was paid comes off your next payment. Your staff agreement has the full rule.
',
  '<p class="gd-p">Every function earns a commission on the rentals it sources: a renter you found yourself. Say so when you enter the rental, the quote or the offer.</p><section class="gd-task" id="commissions-mark-who-found-the-client" data-gd-task><h2 class="gd-h2">Mark who found the client</h2><p class="gd-p">Every rental, quote and offer you enter asks: <b class="gd-ui">I sourced this client</b> or <b class="gd-ui">Entered for CarmaCars</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Choose <b class="gd-ui">I sourced this client</b> when you found the renter yourself: someone you know, your own post or your own outreach.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose <b class="gd-ui">Entered for CarmaCars</b> when the renter came to CarmaCars: the website, the phone line, a walk-in, a partner.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A website request earns nothing by itself. If you sourced it anyway, choose I sourced this client on its offer: an Admin decides.</div></li></ol></div><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col"></th><th scope="col">Commission</th></tr></thead><tbody><tr><td>Sales</td><td>Commission only, with no base pay and no set hours. By the rental days of the month: under 50 days 10%, from 50 days 15%, from 100 days 20%, on all of that month&#39;s rentals</td></tr><tr><td>Customer service, finance, fleet</td><td>10%</td></tr><tr><td>How much</td><td>The rate on the rental charge before tax, after discounts, with late extra days; never on delivery, kilometres, add-ons or anything else bought. Only a refund of the rental charge comes off</td></tr><tr><td>When earned</td><td>When the rental is completed and paid in full. Never on a cancelled, refunded, unpaid or charged-back rental, or on your own or a household rental</td></tr><tr><td>Your home address</td><td>It must be in your profile. Until it is, a commission waits as not earned yet, and you cannot add a rental or mark I sourced this client</td></tr><tr><td>Paid</td><td>After an Admin approves it, by transfer or on your pay statement. My sales shows each step: not earned yet, pending approval, approved, paid, reversed</td></tr></tbody></table></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A refund or chargeback after a commission was paid comes off your next payment. Your staff agreement has the full rule.</div></aside></section>');
select app.guide_release_section('va', 'live-visitors-and-live-chat', 'chapter', 'commissions', 'Customer service and Sales see who is on the site now and answer the live chat. The CarmaCars assistant answers first; you take over whenever you want.

## Live visitors

1. Open **My work** > **Live visitors**. Each visitor shows a name when known, otherwise "Visitor from Toronto, phone", the page and car they are on, and this visit''s pages.
2. Badges are buying signals: "Viewing spree: 6 cars in 10 minutes", "Opened offer CC-1042, not answered", "Left the pay page", "Started a request and stopped" and more.
3. Press **Pages** for the whole visit. Press **Start a chat**, write a short friendly message and press **Send**: the visitor sees it in a bubble.

## Follow-ups

Signals of known visitors raise tasks on To do with what to do, for example "Call or message Maya Chen: opened offer CC-1042 twice, no answer for 6 hours". Call or message, then mark the task done. A task closes by itself when the renter answers or pays. Follow-ups done count in My sales.

Renters also get one polite reminder email (and at most one more) when they leave an offer, the pay page or a change unanswered. Taking the follow-up task, a chat with you or a message from you stops these reminders: you are handling it.

## Live chat

1. Open **My work** > **Live chat**. The menu counts chats waiting for a person. Reply within 5 minutes.
2. Choose a conversation. Beside it: the visitor''s page, pages and signals, and the renter''s bookings when known.
3. Press **Take over** (or just write a reply): the assistant stops. Write and press **Send** or Enter. The visitor sees when you type.
4. **Hand back to the assistant** when you are done, or **Close**. A visitor who gave an email gets a copy of the chat.
5. Tick "Email me when a chat waits (while I am on shift)" or desktop alerts if you want them.

> Tip: Prices: send a quote from New quote, never a price from memory. If you handled the chat, choose "I sourced this client" on the quote; nothing is credited by itself.
', 'Live visitors and live chat', 'Who is on the site, how likely each visitor is to book, one-click actions, follow-ups, the chat inbox.',
  'Customer service and Sales see who is on the site now and answer the live chat. The CarmaCars assistant answers first; you take over whenever you want.

## Live visitors

1. Open **My work** > **Live visitors**. The menu shows how many hot visitors are on the site. Each visitor shows a booking likelihood from 0 to 100 (Hot, Warm or Cold); the most likely to book come first.
2. "Why" gives the three strongest reasons, for example "Pickup tomorrow · Saw $320 for 3 days · Tapped to call". The badges are all the signals; the dots say how strong each is.
3. Each visitor shows a name when known, otherwise "Visitor from Toronto, phone", the page and car they are on, how many others look at that car now, and this visit''s pages.
4. Suggested: the next step and a message. Press **Invite to chat with this message**, or **Edit the message** first. Sales can **Offer a 10% discount code** (one per visitor a week). **Assign to Sales** hands the visitor to Sales with a task. When their dates are taken, **Suggest a similar free car** writes the message for you.
5. Press **Pages** for the whole visit. Press **Start a chat** to write your own short friendly message and press **Send**: the visitor sees it in a bubble.
6. A hot visitor raises an alert at the top of the page. Each action shows on the visitor ("Invited by Lena, 2 min ago"), so check it before writing.

## Follow-ups

Signals of known visitors raise tasks on To do with what to do, for example "Call or message Maya Chen: opened offer CC-1042 twice, no answer for 6 hours". Call or message, then mark the task done. A task closes by itself when the renter answers or pays. Follow-ups done count in My sales.

Renters also get one polite reminder email (and at most one more) when they leave an offer, the pay page or a change unanswered. Taking the follow-up task, a chat with you or a message from you stops these reminders: you are handling it.

## Live chat

1. Open **My work** > **Live chat**. The menu counts chats waiting for a person. Reply within 5 minutes.
2. Choose a conversation. Beside it: the visitor''s page, pages and signals, and the renter''s bookings when known.
3. Press **Take over** (or just write a reply): the assistant stops. Write and press **Send** or Enter. The visitor sees when you type.
4. **Hand back to the assistant** when you are done, or **Close**. A visitor who gave an email gets a copy of the chat.
5. Tick "Email me when a chat waits (while I am on shift)" or desktop alerts if you want them.

> Tip: Prices: send a quote from New quote, never a price from memory. If you handled the chat, choose "I sourced this client" on the quote; nothing is credited by itself.
',
  '<p class="gd-p">Customer service and Sales see who is on the site now and answer the live chat. The CarmaCars assistant answers first; you take over whenever you want.</p><section class="gd-task" id="live-visitors-and-live-chat-live-visitors" data-gd-task><h2 class="gd-h2">Live visitors</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">My work</b> &gt; <b class="gd-ui">Live visitors</b>. The menu shows how many hot visitors are on the site. Each visitor shows a booking likelihood from 0 to 100 (Hot, Warm or Cold); the most likely to book come first.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">&quot;Why&quot; gives the three strongest reasons, for example &quot;Pickup tomorrow · Saw $320 for 3 days · Tapped to call&quot;. The badges are all the signals; the dots say how strong each is.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Each visitor shows a name when known, otherwise &quot;Visitor from Toronto, phone&quot;, the page and car they are on, how many others look at that car now, and this visit&#39;s pages.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Suggested: the next step and a message. Press <b class="gd-ui">Invite to chat with this message</b>, or <b class="gd-ui">Edit the message</b> first. Sales can <b class="gd-ui">Offer a 10% discount code</b> (one per visitor a week). <b class="gd-ui">Assign to Sales</b> hands the visitor to Sales with a task. When their dates are taken, <b class="gd-ui">Suggest a similar free car</b> writes the message for you.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press <b class="gd-ui">Pages</b> for the whole visit. Press <b class="gd-ui">Start a chat</b> to write your own short friendly message and press <b class="gd-ui">Send</b>: the visitor sees it in a bubble.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">A hot visitor raises an alert at the top of the page. Each action shows on the visitor (&quot;Invited by Lena, 2 min ago&quot;), so check it before writing.</div></li></ol></div></section><section class="gd-task" id="live-visitors-and-live-chat-follow-ups" data-gd-task><h2 class="gd-h2">Follow-ups</h2><p class="gd-p">Signals of known visitors raise tasks on To do with what to do, for example &quot;Call or message Maya Chen: opened offer CC-1042 twice, no answer for 6 hours&quot;. Call or message, then mark the task done. A task closes by itself when the renter answers or pays. Follow-ups done count in My sales.</p><p class="gd-p">Renters also get one polite reminder email (and at most one more) when they leave an offer, the pay page or a change unanswered. Taking the follow-up task, a chat with you or a message from you stops these reminders: you are handling it.</p></section><section class="gd-task" id="live-visitors-and-live-chat-live-chat" data-gd-task><h2 class="gd-h2">Live chat</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">My work</b> &gt; <b class="gd-ui">Live chat</b>. The menu counts chats waiting for a person. Reply within 5 minutes.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose a conversation. Beside it: the visitor&#39;s page, pages and signals, and the renter&#39;s bookings when known.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Take over</b> (or just write a reply): the assistant stops. Write and press <b class="gd-ui">Send</b> or Enter. The visitor sees when you type.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Hand back to the assistant</b> when you are done, or <b class="gd-ui">Close</b>. A visitor who gave an email gets a copy of the chat.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Tick &quot;Email me when a chat waits (while I am on shift)&quot; or desktop alerts if you want them.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Prices: send a quote from New quote, never a price from memory. If you handled the chat, choose &quot;I sourced this client&quot; on the quote; nothing is credited by itself.</div></aside></section>');
select app.guide_release_section('va', 'texts-and-calls', 'chapter', 'live-visitors-and-live-chat', null, 'Texts and calls', 'Reading and answering texts, suggestions, unknown callers and missed calls.',
  'Customer service and Sales answer texts to the CarmaCars number in the same place as live chat. Every call and text is kept with the renter, owner or lead it belongs to.

## Answer a text

1. Open **My work** > **Live chat** and press **Texts and calls**. Unread texts and missed calls are counted on each number.
2. Choose a number: calls and texts in order, and beside them who it is, with their bookings.
3. Write the text and press **Send text**. It goes from the CarmaCars number.
4. **Suggest a reply** writes a draft into the box. Read it and change it: it is never sent until you press Send text.

## Unknown callers

Press **Unknown callers**. Type the name if they told you and press **Create lead**, or find the renter and press **Link to** their name.

## Missed calls

A missed call gives you the task "Missed call from ..." when you have Live chat or Texts and calls open; otherwise it waits in the customer service queue. Call back with the Call button, or text, then mark the task done. Quo itself texts the caller back, so do not send the same message again.

> Tip: A number that texted STOP gets no texts from us, booking texts included, until they text START. Prices go in a quote, never in a text from memory.
',
  '<p class="gd-p">Customer service and Sales answer texts to the CarmaCars number in the same place as live chat. Every call and text is kept with the renter, owner or lead it belongs to.</p><section class="gd-task" id="texts-and-calls-answer-a-text" data-gd-task><h2 class="gd-h2">Answer a text</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">My work</b> &gt; <b class="gd-ui">Live chat</b> and press <b class="gd-ui">Texts and calls</b>. Unread texts and missed calls are counted on each number.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose a number: calls and texts in order, and beside them who it is, with their bookings.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Write the text and press <b class="gd-ui">Send text</b>. It goes from the CarmaCars number.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Suggest a reply</b> writes a draft into the box. Read it and change it: it is never sent until you press Send text.</div></li></ol></div></section><section class="gd-task" id="texts-and-calls-unknown-callers" data-gd-task><h2 class="gd-h2">Unknown callers</h2><p class="gd-p">Press <b class="gd-ui">Unknown callers</b>. Type the name if they told you and press <b class="gd-ui">Create lead</b>, or find the renter and press <b class="gd-ui">Link to</b> their name.</p></section><section class="gd-task" id="texts-and-calls-missed-calls" data-gd-task><h2 class="gd-h2">Missed calls</h2><p class="gd-p">A missed call gives you the task &quot;Missed call from ...&quot; when you have Live chat or Texts and calls open; otherwise it waits in the customer service queue. Call back with the Call button, or text, then mark the task done. Quo itself texts the caller back, so do not send the same message again.</p><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A number that texted STOP gets no texts from us, booking texts included, until they text START. Prices go in a quote, never in a text from memory.</div></aside></section>');
select app.guide_release_section('va', 'assistant', 'chapter', 'add-ons', null, 'Assistant', 'Ask about today, bookings, cars and money; confirm the changes it prepares.',
  'The assistant answers questions from live data and prepares changes for you. It works only through the same steps as the screens, with your own permissions: it cannot see or do anything you could not do yourself. Nothing changes until you confirm.

## Open it

Press **Assistant** at the top of the menu, or press Ctrl and / together (Cmd and / on a Mac). Esc closes it.

1. Type a question or what you want done, in your own words, and press Enter. Examples: "What needs doing today?", "Who has the Tesla?", "Is the Corolla free from 2026-11-02 to 2026-11-04?", "Find booking R-000123".
2. Answers come as cards with links: open one to go straight to the screen.
3. If something is missing or more than one thing matches, it asks and lists the choices. Press the one you mean.

## Changes: a card to confirm

1. Ask for a change, for example "Record a $900 e-Transfer on INV-1053 dated 2026-10-15 reference CA12345".
2. The assistant shows a card: "Record a $900 e-Transfer on INV-1053 for Karan Vakil, dated Oct 15?". Read it, then press **Confirm** or **Cancel**.
3. Confirmed, it runs the same step as the screen and its pop-up, with the same checks. If the step is not allowed for you, or a detail is wrong, it says why and nothing changes.
4. Every change is in the audit log under your name, marked "via assistant". A card older than 30 minutes no longer runs: ask again.

Messages: ask it to draft a message to a renter or an owner. It writes the text; press **Copy**, open the conversation and send it yourself.

> Tip: When the day''s included AI usage is used, the assistant says it is unavailable until tomorrow. Everything still works from the screens and pop-ups.
',
  '<p class="gd-p">The assistant answers questions from live data and prepares changes for you. It works only through the same steps as the screens, with your own permissions: it cannot see or do anything you could not do yourself. Nothing changes until you confirm.</p><section class="gd-task" id="assistant-open-it" data-gd-task><h2 class="gd-h2">Open it</h2><p class="gd-p">Press <b class="gd-ui">Assistant</b> at the top of the menu, or press Ctrl and / together (Cmd and / on a Mac). Esc closes it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Type a question or what you want done, in your own words, and press Enter. Examples: &quot;What needs doing today?&quot;, &quot;Who has the Tesla?&quot;, &quot;Is the Corolla free from 2026-11-02 to 2026-11-04?&quot;, &quot;Find booking R-000123&quot;.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Answers come as cards with links: open one to go straight to the screen.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">If something is missing or more than one thing matches, it asks and lists the choices. Press the one you mean.</div></li></ol></div></section><section class="gd-task" id="assistant-changes-a-card-to-confirm" data-gd-task><h2 class="gd-h2">Changes: a card to confirm</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Ask for a change, for example &quot;Record a $900 e-Transfer on INV-1053 dated 2026-10-15 reference CA12345&quot;.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The assistant shows a card: &quot;Record a $900 e-Transfer on INV-1053 for Karan Vakil, dated Oct 15?&quot;. Read it, then press <b class="gd-ui">Confirm</b> or <b class="gd-ui">Cancel</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Confirmed, it runs the same step as the screen and its pop-up, with the same checks. If the step is not allowed for you, or a detail is wrong, it says why and nothing changes.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Every change is in the audit log under your name, marked &quot;via assistant&quot;. A card older than 30 minutes no longer runs: ask again.</div></li></ol></div><p class="gd-p">Messages: ask it to draft a message to a renter or an owner. It writes the text; press <b class="gd-ui">Copy</b>, open the conversation and send it yourself.</p><aside class="gd-box"><span class="gd-lbl">Tip</span><div>When the day&#39;s included AI usage is used, the assistant says it is unavailable until tomorrow. Everything still works from the screens and pop-ups.</div></aside></section>');
select app.guide_release_section('va', 'shared-tools', 'chapter', 'assistant', 'Every function has the calendar and Find a renter. Use them to answer questions fast.

## The calendar

1. Every car, its bookings, requests and blocks. The red line is now.
2. Use the arrows, Today and the range to move around, or search by plate, booking or name.
3. Fleet and customer service can remove a cleaning block from its side panel (**Remove the block**) when a car is ready sooner.

![](/guides/img/va-cs-09-calendar-desktop-541a6da5.jpg "desktop; size: 1230 800; address: carmacars.ca/va/calendar; pins: 1 60.2 33.8, 2 28.5 17.5")

## Find a renter

1. Search by name, email, phone or booking number.
2. Opening a renter''s private details asks for a reason (**Open with a reason**). It is kept in the access log.

![](/guides/img/va-cs-07-renters-desktop-99cfd0ef.jpg "desktop; size: 1230 240; address: carmacars.ca/va/renters; pins: 1 68.3 34.6")
', 'Shared tools', 'The calendar and Find a renter.',
  'Every function has the calendar and Find a renter. Use them to answer questions fast.

## The calendar

1. Every car, its bookings, requests and blocks. The red line is now.
2. Use the arrows, Today and the range to move around, or search by plate, booking or name.
3. Fleet and customer service can remove a cleaning block from its side panel (**Remove the block**) when a car is ready sooner.

![](/guides/img/va-cs-09-calendar-desktop-541a6da5.jpg "desktop; size: 1230 800; address: carmacars.ca/va/calendar; pins: 1 60.2 33.8, 2 28.5 17.5")

## Find a car

**My work** > **Find a car**. A renter quotes the car code on the car''s page (like CC-7F3A).

1. Type the car code, a plate, a VIN or the name. Each car shows its code, plate, status and its page on the site.
2. In Add a rental, type the car code or plate in the box above Car to choose it.

## Find a renter

1. Search by name, email, phone or booking number.
2. Opening a renter''s private details asks for a reason (**Open with a reason**). It is kept in the access log.

![](/guides/img/va-cs-07-renters-desktop-99cfd0ef.jpg "desktop; size: 1230 240; address: carmacars.ca/va/renters; pins: 1 68.3 34.6")
',
  '<p class="gd-p">Every function has the calendar and Find a renter. Use them to answer questions fast.</p><section class="gd-task" id="shared-tools-the-calendar" data-gd-task><h2 class="gd-h2">The calendar</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Every car, its bookings, requests and blocks. The red line is now.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Use the arrows, Today and the range to move around, or search by plate, booking or name.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Fleet and customer service can remove a cleaning block from its side panel (<b class="gd-ui">Remove the block</b>) when a car is ready sooner.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/calendar</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/800"><img src="/guides/img/va-cs-09-calendar-desktop-541a6da5.jpg" alt="" loading="lazy" decoding="async" width="1230" height="800"><span class="gd-pin" style="left:60.2%;top:33.8%" aria-hidden="true">1</span><span class="gd-pin" style="left:28.5%;top:17.5%" aria-hidden="true">2</span></div></div></figure></div></section><section class="gd-task" id="shared-tools-find-a-car" data-gd-task><h2 class="gd-h2">Find a car</h2><p class="gd-p"><b class="gd-ui">My work</b> &gt; <b class="gd-ui">Find a car</b>. A renter quotes the car code on the car&#39;s page (like CC-7F3A).</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Type the car code, a plate, a VIN or the name. Each car shows its code, plate, status and its page on the site.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">In Add a rental, type the car code or plate in the box above Car to choose it.</div></li></ol></div></section><section class="gd-task" id="shared-tools-find-a-renter" data-gd-task><h2 class="gd-h2">Find a renter</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Search by name, email, phone or booking number.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Opening a renter&#39;s private details asks for a reason (<b class="gd-ui">Open with a reason</b>). It is kept in the access log.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/renters</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/240"><img src="/guides/img/va-cs-07-renters-desktop-99cfd0ef.jpg" alt="" loading="lazy" decoding="async" width="1230" height="240"><span class="gd-pin" style="left:68.3%;top:34.6%" aria-hidden="true">1</span></div></div></figure></div></section>');
select app.guide_release_section('investor', 'the-investor-deck', 'chapter', 'how-your-returns-work', null, 'The investor deck', 'What CarmaCars built, how it makes money, and a calculator for your Return.',
  'The investor deck tells the CarmaCars story in slides: the problem we solve, how the business makes money, every feature of the platform with its real screen, the investment offer, its risks, and how your Return builds.

## Open the deck

1. On **Investments**, press **Open the deck**, or press **Investor deck** in the menu.
2. Move with **Previous** and **Next**, the arrow keys, or a swipe left or right on a phone. The list at the top jumps to any slide.
3. Press **Download PDF** to save or print it: each slide prints on its own landscape page.

## The calculator

1. Enter an amount (at least the minimum investment) and choose **Paid monthly**, **Reinvested** or **Reinvest, then paid**.
2. Choose how many years to show and the Investment Date.
3. You see when the lockup ends, your first payment date, what a full month pays, what is paid to you for the period, and your Invested Amount at the end, with a chart and a month-by-month table.

The calculator follows your agreement exactly: no Return for the lockup, then one twelfth of the Yearly Percentage on the Invested Amount each month, by days for a part month, paid on the 15th of the next month or added to the Invested Amount at month end.

> Good to know: The examples use the yearly percentage of our current offer. Your own percentage is the one in your agreement. Every example and figure in the deck is an illustration, not a forecast or a promise, and is not part of any offering memorandum.
',
  '<p class="gd-p">The investor deck tells the CarmaCars story in slides: the problem we solve, how the business makes money, every feature of the platform with its real screen, the investment offer, its risks, and how your Return builds.</p><section class="gd-task" id="the-investor-deck-open-the-deck" data-gd-task><h2 class="gd-h2">Open the deck</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On <b class="gd-ui">Investments</b>, press <b class="gd-ui">Open the deck</b>, or press <b class="gd-ui">Investor deck</b> in the menu.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Move with <b class="gd-ui">Previous</b> and <b class="gd-ui">Next</b>, the arrow keys, or a swipe left or right on a phone. The list at the top jumps to any slide.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Download PDF</b> to save or print it: each slide prints on its own landscape page.</div></li></ol></div></section><section class="gd-task" id="the-investor-deck-the-calculator" data-gd-task><h2 class="gd-h2">The calculator</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Enter an amount (at least the minimum investment) and choose <b class="gd-ui">Paid monthly</b>, <b class="gd-ui">Reinvested</b> or <b class="gd-ui">Reinvest, then paid</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose how many years to show and the Investment Date.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">You see when the lockup ends, your first payment date, what a full month pays, what is paid to you for the period, and your Invested Amount at the end, with a chart and a month-by-month table.</div></li></ol></div><p class="gd-p">The calculator follows your agreement exactly: no Return for the lockup, then one twelfth of the Yearly Percentage on the Invested Amount each month, by days for a part month, paid on the 15th of the next month or added to the Invested Amount at month end.</p><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>The examples use the yearly percentage of our current offer. Your own percentage is the one in your agreement. Every example and figure in the deck is an illustration, not a forecast or a promise, and is not part of any offering memorandum.</div></aside></section>');
-- GUIDES VEHICLE PAGES END
