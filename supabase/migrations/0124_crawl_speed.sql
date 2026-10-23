-- 0124_crawl_speed.sql
-- Faster discovery and crawling of the search pages (docs/changes/2026-10-23-crawl-speed.md).
--
-- 1. The IndexNow sweep walks every sitemap address, the priority list first: the fleet's cars, the landing pages, the
--    guides and the model pages (sitemap_all), then the priority sitemap (0115: the makes, the popular models, the
--    places nearest us), then every place sitemap file (0095), then the vehicle sitemaps as before (0097). One cursor
--    (indexnow_sweep.phase, p_i, p_pos beside 0097's file_i and pos), one daily quota, one back-off; a round that ends
--    starts again with the priority list. Each claim stops after 4 seconds of database time (0097's had no clock: 5,000
--    steps of the vehicle files could pass the API's statement limit, and a claim that times out sends nothing, again
--    every five minutes), and a stretch with no address (files of places without pages) moves the cursor at once
--    (0097's cursor only moved when a batch was sent, so an empty stretch longer than one claim was never passed).
-- 2. The search job runs while the sweep has priority or place addresses to send (0104 waited for the vehicle catalog).
-- 3. public.seo_hub_links: the popular makes, models, cities and services of the priority list, for the footer's
--    "Popular" links (every page links to the hubs, so discovery does not depend on the sitemaps alone).
-- 4. app.gsc_sitemap_log: each Search Console sitemap's figures (submitted, indexed, errors, pending) as the gsc workflow
--    reads them every three hours, to watch discovery per file.

-- ---------------------------------------------------------------- 1. the sweep, priority first
alter table indexnow_sweep
  add column if not exists phase text not null default 'priority' check (phase in ('priority', 'places', 'vehicles')),
  add column if not exists p_i integer not null default 0,
  add column if not exists p_pos bigint not null default 0;
comment on column indexnow_sweep.phase is 'Where the IndexNow sweep is (0124): priority (the site''s own pages and the priority sitemap), places (the place sitemap files, p_i the file and p_pos the address in it), vehicles (0097''s file_i and pos). A round ends with the vehicles and starts again with the priority list.';
-- the next batches start with the priority list; the vehicle cursor is kept for when the sweep comes back to it
update indexnow_sweep set phase = 'priority', p_i = 0, p_pos = 0, updated_at = now();

-- The priority list in its order: the site's own pages (cars, landing pages, guides, model pages), then the priority
-- sitemap in its order; each address once.
create or replace function app.indexnow_priority_paths() returns table (path text, o bigint)
language sql stable security definer set search_path = public, app as $$
  select x.path, min(x.o) o from (
    select s.path, 0::bigint o from public.sitemap_all() s where s.kind in ('car', 'landing', 'article', 'model_hub')
    union all
    select c.path, 1 + c.sort::bigint from app.sitemap_priority_cache c) x
   group by x.path
$$;

-- The next addresses of the vehicle sitemaps after (p_file_i, p_pos), at most p_room, until p_deadline: 0097's walk of
-- the arithmetic index (the level files by row, the tiers files by pair) with a clock.
create or replace function app.indexnow_vehicle_batch(p_room integer, p_file_i bigint, p_pos bigint, p_deadline timestamptz)
returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_paths text[] := '{}';
  v_more text[];
  base text[]; nb integer; nt integer; per bigint; trees text[]; v_total bigint;
  v_i bigint := coalesce(p_file_i, 0); v_pos bigint := coalesce(p_pos, -1); v_last bigint;
  v_prefix text; v_k bigint; v_steps integer := 0;
begin
  select coalesce(array_agg(f.file order by f.file), '{}') into base from app.vehicle_sitemap_files() f;
  nb := cardinality(base);
  select files into nt from app.vpage_tier_shape();
  per := nb + coalesce(nt, 0);
  select coalesce(array_agg(t.prefix), '{}') into trees from app.vpage_trees() t;
  v_total := per * cardinality(trees);
  if v_total = 0 then return jsonb_build_object('paths', '[]'::jsonb, 'file_i', 0, 'pos', -1, 'files', 0, 'done', true); end if;
  if v_i >= v_total then v_i := 0; v_pos := -1; end if;
  while cardinality(v_paths) < p_room and v_i < v_total and v_steps < 5000 and clock_timestamp() < p_deadline loop
    v_steps := v_steps + 1;
    v_prefix := trees[(v_i / per)::integer + 1];
    v_k := v_i % per;
    v_last := null; v_more := '{}';
    if v_k >= nb then
      exit when p_room - cardinality(v_paths) < 13 and cardinality(v_paths) > 0;
      select coalesce(array_agg(app.vpage_tree_path(v_prefix, x.path) order by x.g, x.path) filter (where x.path is not null), '{}'), max(x.g) into v_more, v_last
        from app.vehicle_tier_sitemap((v_k - nb + 1)::integer, v_pos, greatest(1, (p_room - cardinality(v_paths)) / 13)) x;
    else
      select coalesce(array_agg(app.vpage_tree_path(v_prefix, x.path) order by x.rn), '{}'), max(x.rn) into v_more, v_last
        from (select r.path, row_number() over (order by r.path) rn from app.vehicle_sitemap(base[v_k + 1]) r) x
       where x.rn > v_pos and x.rn <= v_pos + (p_room - cardinality(v_paths));
    end if;
    v_paths := v_paths || v_more;
    if v_last is null then v_i := v_i + 1; v_pos := -1; else v_pos := v_last; end if;
  end loop;
  return jsonb_build_object('paths', to_jsonb(v_paths), 'file_i', v_i, 'pos', v_pos, 'files', v_total, 'done', v_i >= v_total);
end $$;

-- The next batch (0097's function, replaced whole): up to p_limit addresses after the cursor, priority list first, then
-- the place files, then the vehicle files, within today's ceiling and 4 seconds; nothing while backing off. The cursor
-- after the batch goes back with the answer (server_indexnow_report); a claim that found no address stores it at once.
create or replace function app.server_indexnow_claim(p_limit integer) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  w indexnow_sweep;
  v_today date := (now() at time zone 'America/Toronto')::date;
  v_deadline timestamptz := clock_timestamp() + interval '4 seconds';
  v_room integer;
  v_paths text[] := '{}';
  v_more text[];
  v_n integer;
  v_phase text; v_i integer; v_pos bigint; v_file_i bigint; v_vpos bigint;
  v_files jsonb; v_f jsonb; v_rows jsonb; v_nf integer;
  v jsonb; v_total bigint;
begin
  select * into w from indexnow_sweep for update;
  if w.day < v_today then update indexnow_sweep set day = v_today, sent_today = 0 returning * into w; end if;
  if not s.indexnow_enabled then return jsonb_build_object('paths', '[]'::jsonb, 'why', 'off'); end if;
  if w.backoff_until > now() then return jsonb_build_object('paths', '[]'::jsonb, 'why', 'backing off', 'until', w.backoff_until); end if;
  v_room := least(coalesce(p_limit, s.indexnow_batch), s.indexnow_batch, greatest(s.indexnow_daily_max - w.sent_today, 0));
  if v_room <= 0 then return jsonb_build_object('paths', '[]'::jsonb, 'why', 'daily ceiling'); end if;
  v_phase := w.phase; v_i := w.p_i; v_pos := w.p_pos; v_file_i := w.file_i; v_vpos := w.pos;

  if v_phase = 'priority' then
    select coalesce(array_agg(x.path order by x.o, x.path), '{}'), count(*) into v_more, v_n
      from (select p.path, p.o from app.indexnow_priority_paths() p order by p.o, p.path offset greatest(v_pos, 0) limit v_room) x;
    v_paths := v_more; v_pos := greatest(v_pos, 0) + v_n;
    if v_n < v_room then v_phase := 'places'; v_i := 0; v_pos := 0; end if;
  end if;

  if v_phase = 'places' and cardinality(v_paths) < v_room then
    v_files := coalesce(public.place_sitemap_files(), '[]'::jsonb);
    v_nf := jsonb_array_length(v_files);
    while cardinality(v_paths) < v_room and v_i < v_nf and clock_timestamp() < v_deadline loop
      v_f := v_files -> v_i;
      v_rows := coalesce(public.place_sitemap(v_f ->> 'vertical', v_f ->> 'term', (v_f ->> 'page')::integer), '[]'::jsonb);
      select coalesce(array_agg(e ->> 'path' order by n), '{}'), count(*) into v_more, v_n
        from jsonb_array_elements(v_rows) with ordinality t(e, n)
       where n > v_pos and n <= v_pos + (v_room - cardinality(v_paths));
      v_paths := v_paths || v_more;
      if v_pos + v_n >= jsonb_array_length(v_rows) then v_i := v_i + 1; v_pos := 0; else v_pos := v_pos + v_n; end if;
    end loop;
    if v_i >= v_nf then v_phase := 'vehicles'; v_i := 0; v_pos := 0; end if;
  end if;

  if v_phase = 'vehicles' and cardinality(v_paths) < v_room and clock_timestamp() < v_deadline then
    v := app.indexnow_vehicle_batch(v_room - cardinality(v_paths), v_file_i, v_vpos, v_deadline);
    v_paths := v_paths || array(select jsonb_array_elements_text(v -> 'paths'));
    v_file_i := (v ->> 'file_i')::bigint; v_vpos := (v ->> 'pos')::bigint; v_total := (v ->> 'files')::bigint;
    -- the end of the vehicle files (or none at all): the next round starts with the priority list
    if (v ->> 'done')::boolean then v_phase := 'priority'; v_i := 0; v_pos := 0; v_file_i := 0; v_vpos := -1; end if;
  end if;

  if cardinality(v_paths) = 0 then
    -- nothing to send: the cursor moves past the empty stretch now (no answer will come back to move it)
    update indexnow_sweep set phase = v_phase, p_i = v_i, p_pos = v_pos, file_i = v_file_i, pos = v_vpos, updated_at = now();
    return jsonb_build_object('paths', '[]'::jsonb, 'why', 'nothing to send', 'phase', v_phase);
  end if;
  return jsonb_build_object('paths', to_jsonb(v_paths),
    'cursor', jsonb_build_object('phase', v_phase, 'p_i', v_i, 'p_pos', v_pos, 'file_i', v_file_i, 'pos', v_vpos),
    'files', v_total, 'phase', w.phase,
    'key', (select indexnow_key from site_settings limit 1));
end $$;

-- What a batch got (0104's function, replaced whole): 2xx moves the cursor (the phase too; a cursor without one is the
-- vehicle files') and counts the addresses; the end of the vehicle files starts the next round with the priority list.
-- 429: the whole queue waits until the Retry-After time when the engine gave one, else until 00:05 tomorrow (Toronto).
-- 403 or 422 (the key refused) waits until tomorrow; anything else (a claim that failed: status 0) 10 minutes. The cursor
-- stays put on a failure.
create or replace function app.server_indexnow_report(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_status integer := coalesce((p ->> 'status')::integer, 0);
  v_n integer := coalesce((p ->> 'count')::integer, 0);
  v_retry integer := nullif(p ->> 'retry_after', '')::integer;
  v_tomorrow integer := greatest(60, extract(epoch from (((now() at time zone 'America/Toronto')::date + 1 + time '00:05') at time zone 'America/Toronto') - now())::integer);
  c jsonb := p -> 'cursor';
  w indexnow_sweep;
  v_wait integer;
begin
  select * into w from indexnow_sweep for update;
  if v_status between 200 and 299 then
    update indexnow_sweep set sent_today = case when day < (now() at time zone 'America/Toronto')::date then 0 else sent_today end + v_n,
           day = (now() at time zone 'America/Toronto')::date, backoff_s = 0, backoff_until = null, last_status = v_status, last_error = null,
           last_at = now(), updated_at = now(),
           phase = case when c is null then phase else coalesce(c ->> 'phase', 'vehicles') end,
           p_i = case when c ? 'p_i' then (c ->> 'p_i')::integer else p_i end,
           p_pos = case when c ? 'p_pos' then (c ->> 'p_pos')::bigint else p_pos end,
           file_i = case when c ? 'file_i' then (c ->> 'file_i')::integer else file_i end,
           pos = case when c ? 'pos' then (c ->> 'pos')::bigint else pos end
     returning * into w;
    if (p ->> 'files') is not null and w.file_i >= (p ->> 'files')::bigint then
      update indexnow_sweep set file_i = 0, pos = -1, rounds = rounds + 1, phase = 'priority', p_i = 0, p_pos = 0 returning * into w;
    end if;
  else
    v_wait := case when v_status = 429 then case when v_retry > 0 then least(v_retry, 172800) else v_tomorrow end
                   when v_status in (403, 422) then v_tomorrow
                   else 600 end;
    update indexnow_sweep set backoff_s = v_wait, backoff_until = now() + make_interval(secs => v_wait), last_status = v_status, last_error = left(p ->> 'error', 300),
           last_at = now(), updated_at = now() returning * into w;
  end if;
  return to_jsonb(w);
end $$;

revoke all on function app.indexnow_priority_paths(), app.indexnow_vehicle_batch(integer, bigint, bigint, timestamptz) from public, anon, authenticated;
grant execute on function app.indexnow_priority_paths(), app.indexnow_vehicle_batch(integer, bigint, bigint, timestamptz) to service_role;

-- ---------------------------------------------------------------- 2. the job runs while the sweep has work
create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

alter function app.server_jobs_due() rename to server_jobs_due_pre0124;
create function app.server_jobs_due() returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v jsonb := app.server_jobs_due_pre0124();
  ps program_settings := app.settings();
  w indexnow_sweep;
begin
  if coalesce((v ->> 'seo')::boolean, true) then return v; end if;
  select * into w from indexnow_sweep;
  return v || jsonb_build_object('seo', ps.indexnow_enabled and w.phase in ('priority', 'places') and not coalesce(w.backoff_until > now(), false)
    and (w.day < (now() at time zone 'America/Toronto')::date or w.sent_today < ps.indexnow_daily_max));
end $$;
select pg_temp.copy_grants('app.server_jobs_due()'::regprocedure, 'app.server_jobs_due_pre0124()'::regprocedure);

-- ---------------------------------------------------------------- 3. the footer's popular hubs
-- From the priority list only (pages that are in search and in the sitemaps): the popular makes and models in their
-- order, the cities nearest us, and the first services (the nearest place of each term), twelve of each at most.
create or replace function public.seo_hub_links() returns jsonb
language sql stable security definer set search_path = public, app as $$
  with c as materialized (select path, sort from app.sitemap_priority_cache),
  mk as (select app.vpage_path(m.slug) path, m.name, min(p.sort) o from vehicle_catalog_popular p join vehicle_catalog_makes m on m.slug = p.make_slug
          where exists (select 1 from c where c.path = app.vpage_path(m.slug)) group by m.slug, m.name order by min(p.sort), m.name limit 12),
  md as (select app.vpage_path(p.make_slug, p.model_slug) path, m.name || ' ' || mo.name as name, p.sort o from vehicle_catalog_popular p
           join vehicle_catalog_makes m on m.slug = p.make_slug join vehicle_catalog_models mo on mo.make_slug = p.make_slug and mo.slug = p.model_slug
          where exists (select 1 from c where c.path = app.vpage_path(p.make_slug, p.model_slug)) order by p.sort, 2 limit 12),
  pl as (select distinct on (c.path) c.path, pl.name, c.sort o from c join places pl on c.path = '/car-rental/' || pl.slug
          where c.path ~ '^/car-rental/[a-z0-9-]+$' order by c.path, pl.id),
  pl12 as (select * from pl order by o limit 12),
  tm as (select distinct on (t.slug) c.path, t.title || ' in ' || pl.name as name, t.vertical, t.sort_order, c.sort o
           from c
           join place_terms t on t.slug = split_part(c.path, '/', 3) and app.place_hub_path(t.vertical, t.slug, split_part(c.path, '/', 4)) = c.path
           join places pl on pl.slug = split_part(c.path, '/', 4)
          where c.path ~ '^/[a-z-]+/[a-z0-9-]+/[a-z0-9-]+$' and t.is_active and t.canonical_slug is null and t.slug <> 'car-rental'
          order by t.slug, c.sort, pl.id),
  tm12 as (select * from tm order by vertical <> 'rental', sort_order, o limit 12)
  select jsonb_build_object(
    'makes', coalesce((select jsonb_agg(jsonb_build_object('path', path, 'name', name) order by o, name) from mk), '[]'::jsonb),
    'models', coalesce((select jsonb_agg(jsonb_build_object('path', path, 'name', name) order by o, name) from md), '[]'::jsonb),
    'places', coalesce((select jsonb_agg(jsonb_build_object('path', path, 'name', name) order by o) from pl12), '[]'::jsonb),
    'services', coalesce((select jsonb_agg(jsonb_build_object('path', path, 'name', name) order by vertical <> 'rental', sort_order, o) from tm12), '[]'::jsonb))
$$;
revoke all on function public.seo_hub_links() from public;
grant execute on function public.seo_hub_links() to anon, authenticated, service_role;

-- ---------------------------------------------------------------- 4. Search Console, per sitemap
create table if not exists app.gsc_sitemap_log (
  id bigserial primary key,
  at timestamptz not null default now(),
  path text not null,
  is_index boolean,
  is_pending boolean,
  last_submitted timestamptz,
  last_downloaded timestamptz,
  errors integer,
  warnings integer,
  submitted bigint,
  indexed bigint
);
create index if not exists gsc_sitemap_log_path_at on app.gsc_sitemap_log (path, at desc);
alter table app.gsc_sitemap_log enable row level security;
revoke all on app.gsc_sitemap_log from public, anon, authenticated;
comment on table app.gsc_sitemap_log is 'Search Console''s figures for each submitted sitemap (0124), stored by the gsc workflow every three hours (90 days kept): submitted is the addresses Google read from the file ("discovered"), indexed what it reports indexed (often 0: Google no longer fills it in). app.gsc_sitemap_latest has the last row of each.';

create or replace function app.gsc_sitemap_store(p jsonb) returns integer
language plpgsql security definer set search_path = public, app as $$
declare n integer;
begin
  insert into app.gsc_sitemap_log (path, is_index, is_pending, last_submitted, last_downloaded, errors, warnings, submitted, indexed)
  select x.path, x.is_index, x.is_pending, x.last_submitted, x.last_downloaded, x.errors, x.warnings, x.submitted, x.indexed
    from jsonb_to_recordset(coalesce(p, '[]'::jsonb)) as x(path text, is_index boolean, is_pending boolean, last_submitted timestamptz, last_downloaded timestamptz,
                                                           errors integer, warnings integer, submitted bigint, indexed bigint)
   where x.path is not null;
  get diagnostics n = row_count;
  delete from app.gsc_sitemap_log where at < now() - interval '90 days';
  return n;
end $$;
revoke all on function app.gsc_sitemap_store(jsonb) from public, anon, authenticated;
grant execute on function app.gsc_sitemap_store(jsonb) to service_role;

create or replace view app.gsc_sitemap_latest with (security_invoker = true) as
  select distinct on (path) path, at, is_index, is_pending, last_downloaded, errors, warnings, submitted, indexed
    from app.gsc_sitemap_log order by path, at desc;
revoke all on app.gsc_sitemap_latest from public, anon, authenticated;
