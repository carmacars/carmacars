-- 0106: the public site stays up while the database is busy (docs/changes/2026-10-22-stay-up-when-busy.md).
--
-- During the vehicle catalog import and the places import, car pages took 5 to 40 s and answered 500 on the Micro
-- compute. Three parts here; the Worker's last good copy of each page is in web/src/lib/edge/page-cache.ts.
--
-- 1. Fail fast: the anon role (every public page's read) gets a 2.5 s statement timeout, so a busy database fails a
--    public read quickly and the Worker answers from the page's last good copy instead of waiting 30 s or more. (A
--    function's own SET statement_timeout does not limit the statement that calls it; the role's setting, which
--    PostgREST applies to every request it runs as anon, does.) The app also stops waiting after 3 s
--    (web/src/lib/db/postgrest.ts ANON_DEADLINE_MS).
-- 2. Gentle catalog import: the batches are staged (COPY into app.vehicle_catalog_staging when the workflow has a
--    database connection, else a plain insert of the batch's rows) and merged into the catalog 2,000 rows per
--    transaction (app.vehicle_catalog_import_merge, ON CONFLICT as before), with a pause and a busy check between
--    transactions (web/scripts/catalog/import.mjs). The catalog-wide refreshes that ran inside every batch (the listing
--    row cache of every car, 0102, on each write to vehicle_catalog_models and vehicle_catalog_trims; the numbering of
--    the trims and every car's catalog match, 0097, on each build of the trims) are deferred while an import writes
--    (the transaction-local setting carmacars.bulk_import) and run once at the end (app.vehicle_catalog_import_finish).
-- 3. Gentle places import: a region is put in place 2,000 staged places per transaction
--    (public.server_places_import_apply_chunk), then its parents, then its counts (server_places_import_region_done);
--    server_places_import_apply still does a whole region in one call (the same result).
-- 4. app.db_busy(): the busy check the imports make before each transaction (client sessions running a statement,
--    sessions waiting on a lock, the longest running statement).

-- ------------------------------------------------------------------ 1. a public read fails fast
alter role anon set statement_timeout = '2500ms';
do $$ begin perform pg_notify('pgrst', 'reload config'); exception when others then null; end $$;

-- ------------------------------------------------------------------ the bulk import setting
create or replace function app.bulk_import() returns boolean
language sql stable as $$ select coalesce(current_setting('carmacars.bulk_import', true), '') = 'on' $$;
comment on function app.bulk_import() is 'True inside an import transaction (0106): the catalog-wide refreshes wait for the import''s end.';

-- the listing row cache's triggers (0102): skipped while an import writes; the import's end refreshes every row
create or replace function app.listing_cache_touch() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  k text := tg_argv[0];
  col text := case k when 'partner' then 'id' when 'vin' then 'vin' else k end;
  v_keys text[];
  v_ids uuid[];
begin
  if app.bulk_import() then return null; end if;
  if k = 'all' then perform app.listing_cache_refresh_all(); return null; end if;
  if tg_op = 'INSERT' then execute format('select array_agg(distinct %I::text) from n', col) into v_keys;
  elsif tg_op = 'DELETE' then execute format('select array_agg(distinct %I::text) from o', col) into v_keys;
  else execute format('select array_agg(distinct x) from (select %1$I::text x from n union select %1$I::text from o) s', col) into v_keys;
  end if;
  if v_keys is null then return null; end if;
  if k = 'partner' then select array_agg(v.id) into v_ids from vehicles v where v.partner_id::text = any (v_keys);
  elsif k = 'vin' then select array_agg(v.id) into v_ids from vehicles v where upper(v.vin) = any (select upper(x) from unnest(v_keys) x);
  else v_ids := v_keys::uuid[];
  end if;
  perform app.listing_cache_refresh(v_ids);
  return null;
end $$;

-- the numbering of the trims and every car's catalog match (0097): once at the import's end, not per build
create or replace function app.vehicle_catalog_number_trims() returns void
language plpgsql security definer set search_path = public, app as $$
begin
  if app.bulk_import() then return; end if;
  update vehicle_catalog_trims t set ord = r.rn
    from (select t.make_slug, t.model_slug, t.year, t.slug,
                 (row_number() over (order by p.sort nulls last, t.year desc, t.make_slug, t.model_slug, t.rank, t.slug))::integer rn
            from vehicle_catalog_trims t left join vehicle_catalog_popular p on p.make_slug = t.make_slug and p.model_slug = t.model_slug) r
   where (t.make_slug, t.model_slug, t.year, t.slug) = (r.make_slug, r.model_slug, r.year, r.slug) and t.ord is distinct from r.rn;
  -- the catalog changed: every car's catalog page again (vehicle_catalog_car_match)
  perform app.vpage_car_match_refresh(null);
end
$$;

-- ------------------------------------------------------------------ 4. the busy check
create or replace function app.db_busy() returns jsonb
language sql stable security definer set search_path = public, app, pg_catalog as $$
  select jsonb_build_object(
    'active', count(*) filter (where a.state = 'active'),
    'waiting', count(*) filter (where a.wait_event_type = 'Lock'),
    'longest_ms', coalesce(round(extract(epoch from max(clock_timestamp() - a.query_start) filter (where a.state = 'active')) * 1000), 0)::bigint)
    from pg_stat_activity a
   where a.pid <> pg_backend_pid() and a.backend_type = 'client backend' and a.datname = current_database()
$$;
comment on function app.db_busy() is 'The imports'' busy check (0106): client sessions running a statement, sessions waiting on a lock, the longest running statement (ms).';
revoke all on function app.db_busy() from public, anon, authenticated;
grant execute on function app.db_busy() to service_role;
create or replace function public.server_db_busy() returns jsonb
language sql stable security definer set search_path = public, app as $$ select app.db_busy() $$;
revoke all on function public.server_db_busy() from public, anon, authenticated;
grant execute on function public.server_db_busy() to service_role;

-- ------------------------------------------------------------------ 2. the catalog: staged, then merged in chunks
-- One row a make, model, model year or make's trim lines, in the order of the batches (a make before its models, a
-- model before its years). Unlogged: a staging table needs no write-ahead log (half the writes), and a crash only
-- empties it (the import then fails and runs again).
create unlogged table if not exists app.vehicle_catalog_staging (
  id bigint generated always as identity primary key,
  kind text not null check (kind in ('make', 'model', 'year', 'trim_lines')),
  make_slug text not null,
  row jsonb not null
);
comment on table app.vehicle_catalog_staging is 'The catalog import''s staged rows (0106), merged 2,000 at a time by app.vehicle_catalog_import_merge.';
revoke all on app.vehicle_catalog_staging from public, anon, authenticated;
grant select, insert, delete, truncate on app.vehicle_catalog_staging to service_role;

-- a batch (the import's JSON: make, models, years, trim_lines) as staged rows
create or replace function app.vehicle_catalog_import_stage(p jsonb) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  v_make text := p -> 'make' ->> 'slug';
  n integer;
begin
  if app.vehicle_catalog_running() is null then raise exception 'No import is running' using errcode = '55000'; end if;
  if v_make is null then raise exception 'A batch names its make' using errcode = '22023'; end if;
  insert into app.vehicle_catalog_staging (kind, make_slug, row)
  select x.kind, v_make, x.row from (
    select 1 o, 0::bigint i, 'make' kind, p -> 'make' row
    union all select 2, m.i, 'model', m.v from jsonb_array_elements(coalesce(p -> 'models', '[]'::jsonb)) with ordinality m(v, i)
    union all select 3, y.i, 'year', y.v from jsonb_array_elements(coalesce(p -> 'years', '[]'::jsonb)) with ordinality y(v, i)
    union all select 4, 0, 'trim_lines', p -> 'trim_lines' where p ? 'trim_lines') x
  order by x.o, x.i;
  get diagnostics n = row_count;
  return n;
end $$;

-- The next p_limit staged rows into the catalog, in one transaction: the same upserts as 0097's batch (a row whose
-- content did not change keeps its updated_at), the catalog-wide refreshes deferred to the import's end.
create or replace function app.vehicle_catalog_import_merge(p_limit integer default 2000) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_imp uuid := app.vehicle_catalog_running();
  v_ids bigint[];
  v_last bigint;
  n_makes integer := 0; n_models integer := 0; n_years integer := 0; n_lines integer := 0;
  t record;
begin
  if v_imp is null then raise exception 'No import is running' using errcode = '55000'; end if;
  perform set_config('carmacars.bulk_import', 'on', true);
  select array_agg(id order by id) into v_ids from (select id from app.vehicle_catalog_staging order by id limit greatest(1, least(coalesce(p_limit, 2000), 20000))) s;
  if v_ids is null then
    perform set_config('carmacars.bulk_import', 'off', true);
    return jsonb_build_object('merged', 0, 'left', 0);
  end if;
  v_last := v_ids[cardinality(v_ids)];
  -- a make split into several batches is staged once a batch: the last row of a key wins (as the batches did)
  insert into vehicle_catalog_makes (slug, name, import_id, content_hash)
  select distinct on (s.make_slug) s.make_slug, s.row ->> 'name', v_imp, md5(s.row ->> 'name')
    from app.vehicle_catalog_staging s where s.id = any (v_ids) and s.kind = 'make' order by s.make_slug, s.id desc
  on conflict (slug) do update set name = excluded.name, import_id = excluded.import_id, content_hash = excluded.content_hash,
    updated_at = case when vehicle_catalog_makes.content_hash is distinct from excluded.content_hash then now() else vehicle_catalog_makes.updated_at end;
  get diagnostics n_makes = row_count;

  insert into vehicle_catalog_models (make_slug, slug, name, key, aliases, vclass, sources, import_id, content_hash)
  select distinct on (s.make_slug, s.row ->> 'slug') s.make_slug, s.row ->> 'slug', s.row ->> 'name', s.row ->> 'key', array(select jsonb_array_elements_text(s.row -> 'aliases')), s.row ->> 'vclass',
         array(select jsonb_array_elements_text(s.row -> 'sources')), v_imp, md5((s.row - 'make')::text)
    from app.vehicle_catalog_staging s where s.id = any (v_ids) and s.kind = 'model' order by s.make_slug, s.row ->> 'slug', s.id desc
  on conflict (make_slug, slug) do update set name = excluded.name, key = excluded.key, aliases = excluded.aliases, vclass = excluded.vclass,
    sources = excluded.sources, import_id = excluded.import_id, content_hash = excluded.content_hash,
    updated_at = case when vehicle_catalog_models.content_hash is distinct from excluded.content_hash then now() else vehicle_catalog_models.updated_at end;
  get diagnostics n_models = row_count;

  insert into vehicle_catalog_years (make_slug, model_slug, year, vclass, variants, dims, recalls, complaints, powertrains, l100_min, l100_max, kwh100_min, ev_range_max, fuels, drives,
                                     sources, import_id, content_hash)
  select distinct on (s.make_slug, y ->> 'model', (y ->> 'year')::smallint)
         s.make_slug, y ->> 'model', (y ->> 'year')::smallint, y ->> 'vclass', coalesce(y -> 'variants', '[]'::jsonb), coalesce(y -> 'dims', '[]'::jsonb),
         coalesce(y -> 'recalls', '[]'::jsonb), coalesce(y -> 'complaints', '{}'::jsonb),
         jsonb_array_length(coalesce(y -> 'variants', '[]'::jsonb)),
         (select min((v ->> 'l100_comb')::numeric) from jsonb_array_elements(y -> 'variants') v),
         (select max((v ->> 'l100_comb')::numeric) from jsonb_array_elements(y -> 'variants') v),
         (select min((v ->> 'kwh100')::numeric) from jsonb_array_elements(y -> 'variants') v),
         (select max((v ->> 'ev_range_km')::integer) from jsonb_array_elements(y -> 'variants') v),
         array(select distinct case v ->> 'fuel' when 'premium' then 'gasoline' else v ->> 'fuel' end from jsonb_array_elements(y -> 'variants') v order by 1),
         array(select distinct v ->> 'drive' from jsonb_array_elements(y -> 'variants') v where v ->> 'drive' is not null order by 1),
         array(select jsonb_array_elements_text(y -> 'sources')), v_imp, md5((y - 'make')::text)
    from app.vehicle_catalog_staging s cross join lateral (select s.row y) r
   where s.id = any (v_ids) and s.kind = 'year'
   order by s.make_slug, y ->> 'model', (y ->> 'year')::smallint, s.id desc
  on conflict (make_slug, model_slug, year) do update set vclass = excluded.vclass, variants = excluded.variants, dims = excluded.dims, recalls = excluded.recalls, complaints = excluded.complaints, powertrains = excluded.powertrains,
    l100_min = excluded.l100_min, l100_max = excluded.l100_max, kwh100_min = excluded.kwh100_min, ev_range_max = excluded.ev_range_max,
    fuels = excluded.fuels, drives = excluded.drives, sources = excluded.sources, import_id = excluded.import_id, content_hash = excluded.content_hash,
    updated_at = case when vehicle_catalog_years.content_hash is distinct from excluded.content_hash then now() else vehicle_catalog_years.updated_at end;
  get diagnostics n_years = row_count;

  -- the list's trim lines of a make, as the list now has them (an Admin's lines are never touched)
  for t in select s.make_slug, s.row from app.vehicle_catalog_staging s where s.id = any (v_ids) and s.kind = 'trim_lines' order by s.id loop
    delete from vehicle_catalog_trim_lines where make_slug = t.make_slug and source = 'seed';
    insert into vehicle_catalog_trim_lines (make_slug, model_slug, from_year, to_year, trims, source, sort)
    select t.make_slug, l ->> 'model', (l ->> 'from')::smallint, (l ->> 'to')::smallint, array(select jsonb_array_elements_text(l -> 'trims')), 'seed', i::integer
      from jsonb_array_elements(coalesce(t.row, '[]'::jsonb)) with ordinality x(l, i);
    n_lines := n_lines + 1;
  end loop;

  delete from app.vehicle_catalog_staging where id <= v_last;
  perform set_config('carmacars.bulk_import', 'off', true);
  return jsonb_build_object('merged', cardinality(v_ids), 'makes', n_makes, 'models', n_models, 'years', n_years, 'trim_lines', n_lines,
                            'left', (select count(*) from app.vehicle_catalog_staging));
end $$;

-- The trims of one make built again (the workflow does one make a transaction before the end), numbering deferred.
create or replace function app.vehicle_catalog_import_trims(p_make text) returns integer
language plpgsql security definer set search_path = public, app as $$
declare n integer;
begin
  if app.vehicle_catalog_running() is null then raise exception 'No import is running' using errcode = '55000'; end if;
  perform set_config('carmacars.bulk_import', 'on', true);
  n := app.vehicle_catalog_build_trims(p_make);
  perform set_config('carmacars.bulk_import', 'off', true);
  return n;
end $$;

-- The batch of 0097, for the SQL fixture and a one-off import: staged and merged in one call.
create or replace function app.vehicle_catalog_import_batch(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r jsonb;
  v_models integer := 0; v_years integer := 0;
begin
  perform app.vehicle_catalog_import_stage(p);
  loop
    r := app.vehicle_catalog_import_merge(20000);
    v_models := v_models + coalesce((r ->> 'models')::integer, 0);
    v_years := v_years + coalesce((r ->> 'years')::integer, 0);
    exit when coalesce((r ->> 'left')::integer, 0) = 0;
  end loop;
  return jsonb_build_object('make', p -> 'make' ->> 'slug', 'models', v_models, 'years', v_years);
end $$;

create or replace function app.vehicle_catalog_import_begin(p jsonb) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid;
  v_cap bigint := (app.settings()).vpage_import_db_cap_mb::bigint * 1024 * 1024;
  v_cat bigint := (select coalesce(sum(pg_total_relation_size(c.oid)), 0) from pg_class c join pg_namespace n on n.oid = c.relnamespace
                    where n.nspname = 'public' and c.relkind = 'r' and c.relname in ('vehicle_catalog_makes', 'vehicle_catalog_models', 'vehicle_catalog_years', 'vehicle_catalog_trims'));
  v_proj bigint;
begin
  -- the database size cap (Admin > Settings > Vehicle pages): the database as it is, less today's catalog, plus the
  -- catalog this import brings (the import's own estimate)
  v_proj := pg_database_size(current_database()) - v_cat + coalesce((p -> 'stats' ->> 'projected_bytes')::bigint, 0);
  if v_proj > v_cap then
    raise exception 'The import would bring the database to % MB, over the cap of % MB (Admin > Settings > Vehicle pages)', v_proj / 1048576, v_cap / 1048576 using errcode = '54000';
  end if;
  update vehicle_catalog_imports set status = 'failed', finished_at = now(), error = 'Replaced by a newer import' where status = 'running';
  truncate app.vehicle_catalog_staging;
  insert into vehicle_catalog_imports (meta) values (coalesce(p, '{}'::jsonb)) returning id into v_id;
  update vehicle_catalog_import_requests set import_id = v_id where import_id is null;
  return v_id;
end $$;

-- The popular list: models it does not have yet are added at the end (an Admin's edits stay); numbered at the end.
create or replace function app.vehicle_catalog_import_popular(p jsonb) returns integer
language plpgsql security definer set search_path = public, app as $$
declare n integer;
begin
  perform set_config('carmacars.bulk_import', 'on', true);
  insert into vehicle_catalog_popular (make_slug, model_slug, sort)
  select e ->> 'make', e ->> 'model', coalesce((select max(sort) from vehicle_catalog_popular), 0) + (e ->> 'sort')::integer
    from jsonb_array_elements(coalesce(p, '[]'::jsonb)) e
   where not exists (select 1 from vehicle_catalog_popular_removed r where r.make_slug = e ->> 'make' and r.model_slug = e ->> 'model')
  on conflict do nothing;
  get diagnostics n = row_count;
  perform set_config('carmacars.bulk_import', 'off', true);
  return n;
end $$;

-- The end of an import: anything still staged is merged, what this import did not bring is removed, the trims are
-- built again (all of them, unless the workflow built them make by make: p.trims_built), and then, once, the trims are
-- numbered, every car's catalog page is matched again and every car's listing row is refreshed.
create or replace function app.vehicle_catalog_import_finish(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_imp uuid := app.vehicle_catalog_running();
  v_makes text[] := array(select jsonb_array_elements_text(coalesce(p -> 'makes', '[]'::jsonb)));
  v_counts jsonb;
begin
  if v_imp is null then raise exception 'No import is running' using errcode = '55000'; end if;
  if cardinality(v_makes) = 0 then raise exception 'An import with no make is refused (the catalog would be emptied)' using errcode = '22023'; end if;
  while exists (select 1 from app.vehicle_catalog_staging) loop perform app.vehicle_catalog_import_merge(20000); end loop;
  perform set_config('carmacars.bulk_import', 'on', true);
  delete from vehicle_catalog_makes where not (slug = any (v_makes));
  delete from vehicle_catalog_models where import_id is distinct from v_imp;
  delete from vehicle_catalog_years where import_id is distinct from v_imp;
  if not coalesce((p ->> 'trims_built')::boolean, false) then perform app.vehicle_catalog_build_trims(); end if;
  perform set_config('carmacars.bulk_import', 'off', true);
  -- the deferred refreshes, once
  perform app.vehicle_catalog_number_trims();
  perform app.listing_cache_refresh_all();
  v_counts := jsonb_build_object('makes', (select count(*) from vehicle_catalog_makes), 'models', (select count(*) from vehicle_catalog_models),
    'years', (select count(*) from vehicle_catalog_years), 'trims', (select count(*) from vehicle_catalog_trims),
    'trim_lines', (select count(*) from vehicle_catalog_trim_lines), 'popular', (select count(*) from vehicle_catalog_popular));
  update vehicle_catalog_imports set status = 'done', finished_at = now(), counts = v_counts where id = v_imp;
  return v_counts;
end $$;

-- A failed import: recorded, the staging emptied, and the deferred refreshes run (the batches merged so far are in).
create or replace function app.vehicle_catalog_import_fail(p jsonb) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  update vehicle_catalog_imports set status = 'failed', finished_at = now(), error = left(coalesce(p ->> 'error', 'failed'), 1000) where status = 'running';
  truncate app.vehicle_catalog_staging;
  perform app.vehicle_catalog_number_trims();
  perform app.listing_cache_refresh_all();
end $$;

revoke all on function app.bulk_import(), app.vehicle_catalog_import_stage(jsonb), app.vehicle_catalog_import_merge(integer), app.vehicle_catalog_import_trims(text),
  app.vehicle_catalog_import_batch(jsonb), app.vehicle_catalog_import_begin(jsonb), app.vehicle_catalog_import_popular(jsonb),
  app.vehicle_catalog_import_finish(jsonb), app.vehicle_catalog_import_fail(jsonb) from public, anon, authenticated;
grant execute on function app.bulk_import(), app.vehicle_catalog_import_stage(jsonb), app.vehicle_catalog_import_merge(integer), app.vehicle_catalog_import_trims(text),
  app.vehicle_catalog_import_batch(jsonb), app.vehicle_catalog_import_begin(jsonb), app.vehicle_catalog_import_popular(jsonb),
  app.vehicle_catalog_import_finish(jsonb), app.vehicle_catalog_import_fail(jsonb) to service_role;

-- ------------------------------------------------------------------ 3. places: a region in chunks
create index if not exists places_staging_slug_idx on places_staging (slug);

-- Phase 'rows': the staged places after p_after (by src_id), p_limit of them: known ones updated, new ones inserted (a
-- slug used already, by a place or another staged place with more people, gets a short suffix, as before). Phase
-- 'parents': their parents set (after every row of the region is in). Returns the last src_id done (null: none left).
create or replace function app.places_import_apply_chunk(p_phase text, p_after bigint, p_limit integer default 2000) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_added integer := 0; v_updated integer := 0; v_parents integer := 0;
  v_ids bigint[];
  v_last bigint;
begin
  if p_phase not in ('rows', 'parents') then raise exception 'The phase is rows or parents' using errcode = '22023'; end if;
  perform set_config('carmacars.bulk_import', 'on', true);
  select array_agg(src_id order by src_id) into v_ids from (
    select s.src_id from places_staging s where p_after is null or s.src_id > p_after order by s.src_id limit greatest(1, least(coalesce(p_limit, 2000), 50000))) x;
  if v_ids is null then return jsonb_build_object('after', null, 'added', 0, 'updated', 0, 'parents', 0); end if;
  v_last := v_ids[cardinality(v_ids)];
  if p_phase = 'rows' then
    update places p set kind = case when p.flags & 16 <> 0 then p.kind else s.kind end, flags = (p.flags & 17) | s.flags,
           region_id = coalesce((select id from place_regions where code = s.region_code), p.region_id),
           lat = s.lat, lng = s.lng, population = s.population, name = case when p.flags & 16 <> 0 then p.name else s.name end, iata = s.iata,
           is_active = true, updated_on = current_date
      from places_staging s where s.src_id = any (v_ids) and s.src_id = p.src_id
       and (p.lat, p.lng, p.population, p.name, p.iata, p.flags & ~17, p.is_active) is distinct from (s.lat, s.lng, s.population, s.name, s.iata, s.flags, true);
    get diagnostics v_updated = row_count;
    -- the rank of each new place among every new staged place of its slug (not only this chunk's)
    with c as (select s.slug from places_staging s where s.src_id = any (v_ids)),
    n as (
      select s.*, row_number() over (partition by s.slug order by s.population desc nulls last, s.src_id) as dup
        from places_staging s where s.slug in (select slug from c) and not exists (select 1 from places p where p.src_id = s.src_id))
    insert into places (kind, region_id, flags, lat, lng, population, src_id, slug, name, country, iata)
    select n.kind, (select id from place_regions where code = n.region_code), n.flags, n.lat, n.lng, n.population, n.src_id,
           case when n.dup = 1 and not exists (select 1 from places p where p.slug = n.slug) and not exists (select 1 from seo_pages sp where sp.slug = n.slug)
                then n.slug else n.slug || '-' || substr(md5(n.src_id::text), 1, 5) end,
           n.name, n.country, n.iata
      from n where n.src_id = any (v_ids)
     order by n.src_id;
    get diagnostics v_added = row_count;
  else
    update places p set parent_id = q.id
      from places_staging s join places q on q.src_id = s.parent_src_id
     where s.src_id = any (v_ids) and s.src_id = p.src_id and p.parent_id is distinct from q.id;
    get diagnostics v_parents = row_count;
  end if;
  return jsonb_build_object('after', v_last, 'added', v_added, 'updated', v_updated, 'parents', v_parents);
end $$;

-- after a region's chunks: its counts on the region and on the run
create or replace function app.places_import_region_done(p_import integer, p_region text, p_counts jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_region smallint := (select id from place_regions where code = p_region);
  v jsonb := jsonb_build_object('staged', (select count(*) from places_staging), 'added', coalesce((p_counts ->> 'added')::integer, 0),
                                'updated', coalesce((p_counts ->> 'updated')::integer, 0), 'parents', coalesce((p_counts ->> 'parents')::integer, 0));
begin
  if v_region is not null then
    update place_regions set loaded_at = now(), skipped = null, places = (select count(*) from places where region_id = v_region) where id = v_region;
  end if;
  update place_imports set counts = counts || jsonb_build_object(p_region, v) where id = p_import;
  return jsonb_build_object('region', p_region) || v;
end $$;

-- one staged region in place in one call (tests, a small region): the chunks in a loop, the same result
create or replace function app.places_import_apply(p_import integer, p_region text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r jsonb;
  v_after bigint;
  v_added integer := 0; v_updated integer := 0; v_parents integer := 0;
  ph text;
begin
  foreach ph in array array['rows', 'parents'] loop
    v_after := null;
    loop
      r := app.places_import_apply_chunk(ph, v_after, 2000);
      exit when r ->> 'after' is null;
      v_after := (r ->> 'after')::bigint;
      v_added := v_added + (r ->> 'added')::integer; v_updated := v_updated + (r ->> 'updated')::integer; v_parents := v_parents + (r ->> 'parents')::integer;
    end loop;
  end loop;
  return app.places_import_region_done(p_import, p_region, jsonb_build_object('added', v_added, 'updated', v_updated, 'parents', v_parents));
end $$;

create or replace function public.server_places_import_apply_chunk(p_phase text, p_after bigint, p_limit integer default 2000) returns jsonb
language sql security definer set search_path = public, app as $$ select app.places_import_apply_chunk(p_phase, p_after, p_limit) $$;
create or replace function public.server_places_import_region_done(p_import integer, p_region text, p_counts jsonb) returns jsonb
language sql security definer set search_path = public, app as $$ select app.places_import_region_done(p_import, p_region, p_counts) $$;

revoke all on function app.places_import_apply_chunk(text, bigint, integer), app.places_import_region_done(integer, text, jsonb), app.places_import_apply(integer, text),
  public.server_places_import_apply_chunk(text, bigint, integer), public.server_places_import_region_done(integer, text, jsonb) from public, anon, authenticated;
grant execute on function app.places_import_apply_chunk(text, bigint, integer), app.places_import_region_done(integer, text, jsonb), app.places_import_apply(integer, text),
  public.server_places_import_apply_chunk(text, bigint, integer), public.server_places_import_region_done(integer, text, jsonb) to service_role;
