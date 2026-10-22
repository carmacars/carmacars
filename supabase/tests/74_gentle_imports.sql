-- 74: gentle imports and fast public reads (migration 0106). The catalog staged and merged in chunks with the
-- catalog-wide refreshes deferred to the end; the places of a region in chunks with the same result as one call; the
-- busy check; the anon role's statement timeout. No fixtures of its own: a test make and test places, the catalog
-- fixture imported again at the end (as suite 55 does).
select test.suite('74 gentle imports');

-- ---------------------------------------------------------------- a public read fails fast
select test.eq('anon: a 2.5 s statement timeout (PostgREST applies it to every anon request)',
  (select array_to_string(s.setconfig, ',') from pg_db_role_setting s join pg_roles r on r.oid = s.setrole where r.rolname = 'anon' and s.setdatabase = 0),
  'statement_timeout=2500ms');
select test.eq('the busy check: active sessions, lock waits, the longest statement',
  (select string_agg(k, ',' order by k) from jsonb_object_keys(app.db_busy()) k), 'active,longest_ms,waiting');
select test.eq('the busy check through the API name', (select string_agg(k, ',' order by k) from jsonb_object_keys(public.server_db_busy()) k), 'active,longest_ms,waiting');

-- ---------------------------------------------------------------- the catalog: staged, merged in chunks
create temp table gi_t0 as select
  (select max(refreshed_at) from app.listing_row_cache) cache_at,
  (select max(updated_at) from vehicle_catalog_car_match) match_at,
  (select count(*) from app.listing_row_cache) cache_rows;
select pg_sleep(0.01);
create temp table gi_imp as select app.vehicle_catalog_import_begin('{"source": "test"}'::jsonb) id;
create temp table gi_batch as select '{
  "make": {"slug": "gi-motors", "name": "Gi Motors"},
  "models": [{"make": "gi-motors", "slug": "alpha", "name": "Alpha", "key": "alpha", "aliases": [], "vclass": "Compact Cars", "sources": ["epa"]},
             {"make": "gi-motors", "slug": "beta", "name": "Beta", "key": "beta", "aliases": ["b"], "vclass": "Small SUV", "sources": ["epa"]}],
  "years": [{"make": "gi-motors", "model": "alpha", "year": 2020, "vclass": "Compact Cars", "variants": [{"id": 1, "fuel": "gasoline", "drive": "FWD", "l100_comb": 7.1, "displ": 2.0}], "sources": ["epa"]},
            {"make": "gi-motors", "model": "alpha", "year": 2021, "vclass": "Compact Cars", "variants": [{"id": 2, "fuel": "premium", "drive": "AWD", "l100_comb": 8.0, "displ": 2.0}], "sources": ["epa"]},
            {"make": "gi-motors", "model": "beta", "year": 2021, "vclass": "Small SUV", "variants": [{"id": 3, "fuel": "electricity", "kwh100": 17.5, "ev_range_km": 400}], "sources": ["epa"]}],
  "trim_lines": [{"model": "alpha", "from": 2020, "to": 2021, "trims": ["Base", "Sport"]}]
}'::jsonb b;
select test.eq('stage: one row a make, model, model year and the trim lines, in order',
  (select app.vehicle_catalog_import_stage(b) from gi_batch), 7);
select test.eq('stage: a make before its models, a model before its years',
  (select string_agg(kind, ',' order by id) from app.vehicle_catalog_staging), 'make,model,model,year,year,year,trim_lines');
select test.eq('merge: 3 rows a transaction (the make and its two models), 4 left',
  (select format('%s %s %s %s', r ->> 'merged', r ->> 'makes', r ->> 'models', r ->> 'left') from (select app.vehicle_catalog_import_merge(3) r) x), '3 1 2 4');
select test.eq('merge: then the years', (select format('%s %s %s', r ->> 'merged', r ->> 'years', r ->> 'left') from (select app.vehicle_catalog_import_merge(3) r) x), '3 3 1');
select test.eq('merge: then the trim lines, none left', (select format('%s %s %s', r ->> 'merged', r ->> 'trim_lines', r ->> 'left') from (select app.vehicle_catalog_import_merge(3) r) x), '1 1 0');
select test.eq('merge: nothing staged, nothing done', (select app.vehicle_catalog_import_merge(3) ->> 'merged'), '0');
select test.eq('the catalog has the make as 0097''s batch writes it',
  (select format('%s|%s|%s|%s|%s', (select name from vehicle_catalog_makes where slug = 'gi-motors'),
     (select string_agg(slug || ':' || array_to_string(aliases, '+'), ',' order by slug) from vehicle_catalog_models where make_slug = 'gi-motors'),
     (select string_agg(model_slug || year || ':' || array_to_string(fuels, '+') || ':' || coalesce(l100_min::text, '-') || ':' || powertrains, ',' order by model_slug, year) from vehicle_catalog_years where make_slug = 'gi-motors'),
     (select string_agg(model_slug || ':' || array_to_string(trims, '+'), ',') from vehicle_catalog_trim_lines where make_slug = 'gi-motors' and source = 'seed'),
     (select count(*) from vehicle_catalog_years where make_slug = 'gi-motors' and import_id = (select id from gi_imp)))),
  'Gi Motors|alpha:,beta:b|alpha2020:gasoline:7.1:1,alpha2021:gasoline:8.0:1,beta2021:electricity:-:1|alpha:Base+Sport|3');
select test.ok('deferred: no listing row refreshed by the import''s writes (0102 refreshed every car on each write of a model)',
  (select max(refreshed_at) from app.listing_row_cache) = (select cache_at from gi_t0));
select test.eq('the trims of the make, built in a transaction of their own', app.vehicle_catalog_import_trims('gi-motors'), 4);
select test.ok('deferred: the trims are not numbered and no car matched again until the end',
  (select bool_and(ord is null) from vehicle_catalog_trims where make_slug = 'gi-motors')
  and (select max(updated_at) from vehicle_catalog_car_match) is not distinct from (select match_at from gi_t0)
  and (select max(refreshed_at) from app.listing_row_cache) = (select cache_at from gi_t0));
select test.eq('the bulk setting ends with the transaction''s call',
  (select app.bulk_import()), false);
do $$ begin perform app.vehicle_catalog_import_merge(10); if app.bulk_import() then raise exception 'still on'; end if; end $$;
select test.ok('the bulk setting is off again inside the same transaction after a merge', true);
-- outside an import the triggers work as before
create temp table gi_t2 as select max(refreshed_at) cache_at from app.listing_row_cache;
select pg_sleep(0.01);
update vehicle_catalog_models set vclass = vclass where make_slug = 'gi-motors';
select test.ok('outside an import a write to the models still refreshes every listing row (0102)',
  (select max(refreshed_at) from app.listing_row_cache) > (select cache_at from gi_t2));

-- the same content again: lastmod stays; a make split in two batches staged into one chunk merges without a conflict
create temp table gi_y as select model_slug, year, updated_at from vehicle_catalog_years where make_slug = 'gi-motors';
select pg_sleep(0.01);
select app.vehicle_catalog_import_stage(b) from gi_batch;
select app.vehicle_catalog_import_stage(jsonb_set(b - 'trim_lines', '{models}', '[]'::jsonb) || '{"years": []}'::jsonb) from gi_batch;
select test.eq('a make staged twice in one chunk: one row a key, the last one wins',
  (select format('%s %s', r ->> 'merged', r ->> 'makes') from (select app.vehicle_catalog_import_merge(2000) r) x), '8 1');
select test.eq('the same content again moves no lastmod',
  (select count(*) from vehicle_catalog_years y join gi_y g using (model_slug, year) where y.make_slug = 'gi-motors' and y.updated_at <> g.updated_at), 0::bigint);

-- the batch of 0097 (the SQL fixture's path) still does a batch in one call
select test.eq('the one-call batch: staged and merged at once',
  (select format('%s %s %s', r ->> 'models', r ->> 'years', (select count(*) from app.vehicle_catalog_staging)) from (select app.vehicle_catalog_import_batch(b) r from gi_batch) x), '2 3 0');

-- a failure: recorded, staging emptied, the deferred refreshes run
select app.vehicle_catalog_import_stage(b) from gi_batch;
select app.vehicle_catalog_import_fail('{"error": "test 74"}'::jsonb);
select test.ok('fail: recorded, the staging emptied, every listing row refreshed',
  (select status = 'failed' and error = 'test 74' from vehicle_catalog_imports where id = (select id from gi_imp))
  and not exists (select 1 from app.vehicle_catalog_staging)
  and (select max(refreshed_at) from app.listing_row_cache) > (select cache_at from gi_t0)
  and (select count(*) from app.listing_row_cache) = (select cache_rows from gi_t0));
select test.throws('no merge without a running import', $$select app.vehicle_catalog_import_merge(10)$$, 'No import is running');
select test.throws('no stage without a running import', $$select app.vehicle_catalog_import_stage('{"make": {"slug": "x", "name": "X"}}'::jsonb)$$, 'No import is running');

-- the fixture again (begin, batches, popular, finish): the test make goes, the trims are numbered and the cars matched
-- once at the end
create temp table gi_t1 as select (select max(updated_at) from vehicle_catalog_car_match) match_at, (select max(refreshed_at) from app.listing_row_cache) cache_at;
select pg_sleep(0.01);
\ir ../seed/vehicle_catalog_fixture.sql
select test.ok('finish: the import is done, the test make removed, every trim numbered',
  (select status = 'done' from vehicle_catalog_imports order by started_at desc limit 1)
  and not exists (select 1 from vehicle_catalog_makes where slug = 'gi-motors')
  and not exists (select 1 from vehicle_catalog_trims where ord is null)
  and (select count(distinct ord) = count(*) from vehicle_catalog_trims));
select test.ok('finish: the cars matched again and their listing rows refreshed, once at the end',
  ((select max(updated_at) from vehicle_catalog_car_match) > (select match_at from gi_t1) or not exists (select 1 from vehicle_catalog_car_match))
  and (select max(refreshed_at) from app.listing_row_cache) > (select cache_at from gi_t1));

-- ---------------------------------------------------------------- places: a region in chunks, the same result
create temp table gi_pimp as select public.server_places_import_begin(array['CA-ON'], array['geonames'], null) as id;
insert into places_staging (src_id, kind, flags, region_code, country, lat, lng, population, parent_src_id, slug, name, iata) values
  (9810001, 5, 2, 'CA-ON', 'CA', 44.1, -79.1, 500, 9810004, 'gi-dupville-on', 'Dupville (small)', null),
  (9810002, 6, 2, 'CA-ON', 'CA', 44.2, -79.2, null, 9810003, 'gi-north-end-on', 'North End', null),
  (9810003, 5, 2, 'CA-ON', 'CA', 44.3, -79.3, 20000, 9810004, 'gi-bigtown-on', 'Bigtown', null),
  (9810004, 3, 2, 'CA-ON', 'CA', 44.4, -79.4, null, 6093943, 'gi-county-on', 'Gi County', null),
  (9810005, 5, 2, 'CA-ON', 'CA', 44.5, -79.5, 90000, 9810004, 'gi-dupville-on', 'Dupville (big)', null);
-- one place a transaction: rows, then parents (a parent staged after its child is linked too)
do $$
declare r jsonb; v_after bigint; ph text; n_added integer := 0; n_parents integer := 0;
begin
  foreach ph in array array['rows', 'parents'] loop
    v_after := null;
    loop
      r := public.server_places_import_apply_chunk(ph, v_after, 1);
      exit when r ->> 'after' is null;
      v_after := (r ->> 'after')::bigint;
      n_added := n_added + (r ->> 'added')::integer; n_parents := n_parents + (r ->> 'parents')::integer;
    end loop;
  end loop;
  perform public.server_places_import_region_done((select id from gi_pimp), 'CA-ON', jsonb_build_object('added', n_added, 'parents', n_parents));
end $$;
select test.eq('chunks: the place with more people keeps the plain slug even when it comes in a later chunk',
  (select string_agg(name || '=' || case when slug = 'gi-dupville-on' then 'plain' when slug ~ '^gi-dupville-on-[0-9a-f]{5}$' then 'suffix' else slug end, ',' order by src_id)
     from places where src_id in (9810001, 9810005)),
  'Dupville (small)=suffix,Dupville (big)=plain');
select test.eq('chunks: parents linked after every row is in, a parent staged after its child too',
  (select string_agg(p.name || '>' || coalesce(q.name, '-'), ',' order by p.src_id) from places p left join places q on q.id = p.parent_id where p.src_id between 9810001 and 9810005),
  'Dupville (small)>Gi County,North End>Bigtown,Bigtown>Gi County,Gi County>Ontario,Dupville (big)>Gi County');
select test.eq('chunks: the run records the region''s counts',
  (select format('%s/%s/%s', c ->> 'staged', c ->> 'added', c ->> 'parents') from place_imports, jsonb_extract_path(counts, 'CA-ON') c where id = (select id from gi_pimp)), '5/5/5');
select test.eq('the one-call apply over the same staging: nothing left to change',
  (select format('%s/%s/%s/%s', r ->> 'staged', r ->> 'added', r ->> 'updated', r ->> 'parents') from (select public.server_places_import_apply((select id from gi_pimp), 'CA-ON') r) x), '5/0/0/0');
update places_staging set population = 95000 where src_id = 9810005;
select test.eq('a changed place is updated by its chunk', (select format('%s %s', r ->> 'updated', r ->> 'added') from (select public.server_places_import_apply_chunk('rows', 9810004, 2000) r) x), '1 0');
select test.throws('the phase is rows or parents', $$select public.server_places_import_apply_chunk('all', null, 10)$$, 'rows or parents');
delete from places where src_id between 9810001 and 9810005;
truncate places_staging;

-- ---------------------------------------------------------------- who may call what
set role anon;
select test.throws('anon cannot merge the catalog', $$select app.vehicle_catalog_import_merge(10)$$, 'permission denied');
select test.throws('anon cannot stage', $$select app.vehicle_catalog_import_stage('{}'::jsonb)$$, 'permission denied');
select test.throws('anon cannot read the busy check', $$select public.server_db_busy()$$, 'permission denied');
select test.throws('anon cannot load places in chunks', $$select public.server_places_import_apply_chunk('rows', null, 10)$$, 'permission denied');
reset role;
