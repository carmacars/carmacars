-- 2120_r36x_ca_addresses.sql
-- Release 36, helper X, task 3. The owner: "Canadian address database to replace Google Maps autocomplete: import Statistics
-- Canada's Open Database of Addresses (ODA) via a GitHub workflow into the DB (Ontario first, then all provinces), with a
-- fast prefix search and the site-wide address autocomplete switched to it (Google only as fallback if configured). Keep
-- storage reasonable."
--   1. ca_addresses: one civic address a row, only the columns the forms need (number, street, unit, city, province, postal
--      code, the point as two reals). No search column is stored: the search key lives only in its index
--      (app.addr_norm of number, street and city, text_pattern_ops), so a prefix ("65 front st w") is one index range scan.
--   2. app.addr_norm: lower case, French accents folded, punctuation to spaces, street types and directions shortened
--      ("Street" -> st, "Avenue" -> ave, "West" -> w), the same for the rows and the typed text.
--   3. public.server_address_search(q, limit): the suggestions ({id: "ca-<n>", label}); public.server_address_get(id): the
--      address in its parts with its point. Service role only (the site's /api/address asks them; Google is asked only
--      when the database has nothing and a key is configured).
--   4. The import (.github/workflows/addresses.yml, web/scripts/addresses/load.mjs): one province at a time, Ontario
--      first, COPY in chunks into ca_addresses, then the province's older rows deleted in id ranges; a province that would
--      take the database past Program settings place_db_cap_mb (the places' cap, 0095) is skipped and named. Each run is
--      recorded in address_imports.
set local check_function_bodies = off;

-- ================================================================ 1. the table
create table if not exists ca_addresses (
  id        bigint generated always as identity primary key,
  province  text not null check (province ~ '^[A-Z]{2}$'),
  num       text check (num is null or length(num) <= 20),
  street    text not null check (length(street) between 1 and 120),
  unit      text check (unit is null or length(unit) <= 20),
  city      text check (city is null or length(city) <= 80),
  postal    text check (postal is null or postal ~ '^[A-Z][0-9][A-Z] [0-9][A-Z][0-9]$'),
  lat       real,
  lng       real
);
comment on table ca_addresses is 'Canadian civic addresses (2120) from Statistics Canada''s Open Database of Addresses (Open Government Licence - Canada), loaded by the addresses workflow, for the address fields'' suggestions. Search through app.addr_norm''s index only.';
alter table ca_addresses enable row level security;
revoke all on ca_addresses from public, anon, authenticated;
grant all on ca_addresses to service_role;

create table if not exists address_imports (
  id           integer generated always as identity primary key,
  provinces    text[] not null default '{}',
  run_url      text,
  status       text not null default 'running' check (status in ('running', 'done', 'failed')),
  counts       jsonb not null default '{}'::jsonb,
  skipped      jsonb not null default '{}'::jsonb,
  started_at   timestamptz not null default now(),
  finished_at  timestamptz
);
comment on table address_imports is 'Each run of the addresses workflow (2120): the provinces asked, the rows loaded per province, the provinces skipped for the size cap.';
alter table address_imports enable row level security;
revoke all on address_imports from public, anon, authenticated;
grant select on address_imports to authenticated;
grant all on address_imports to service_role;
create policy admin_read on address_imports for select to authenticated using (app.is_admin());

-- ================================================================ 2. the search key
create or replace function app.addr_norm(p text) returns text
language sql immutable parallel safe as $$
  select btrim(regexp_replace(
    regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(
    regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(
      ' ' || regexp_replace(lower(translate(coalesce(p, ''), 'àâäáãåçéèêëíìîïñóòôöõúùûüýÿÀÂÄÁÃÅÇÉÈÊËÍÌÎÏÑÓÒÔÖÕÚÙÛÜÝ', 'aaaaaaceeeeiiiinooooouuuuyyAAAAAACEEEEIIIINOOOOOUUUUY')), '[^a-z0-9]+', ' ', 'g') || ' ',
      ' street ', ' st ', 'g'), ' avenue ', ' ave ', 'g'), ' road ', ' rd ', 'g'), ' drive ', ' dr ', 'g'), ' boulevard ', ' blvd ', 'g'),
      ' crescent ', ' cres ', 'g'), ' court ', ' crt ', 'g'), ' place ', ' pl ', 'g'), ' lane ', ' ln ', 'g'), ' circle ', ' cir ', 'g'),
      ' terrace ', ' terr ', 'g'), ' highway ', ' hwy ', 'g'), ' north ', ' n ', 'g'), ' south ', ' s ', 'g'), ' east ', ' e ', 'g'),
      ' west ', ' w ', 'g'))
$$;
comment on function app.addr_norm(text) is 'The address search key (2120): lower case, accents folded, punctuation to spaces, common street types and directions shortened. Immutable: the index of ca_addresses is built on it.';

create index if not exists ca_addresses_key on ca_addresses (app.addr_norm(coalesce(num, '') || ' ' || street || ' ' || coalesce(city, '')) text_pattern_ops);

-- ================================================================ 3. search and one address
create or replace function app.addr_label(p_num text, p_street text, p_unit text, p_city text, p_province text, p_postal text) returns text
language sql immutable as $$
  select concat_ws(', ', btrim(coalesce(p_num, '') || ' ' || p_street), case when p_unit is not null then 'Unit ' || p_unit end, p_city,
                   btrim(p_province || ' ' || coalesce(p_postal, '')))
$$;

create or replace function public.server_address_search(p_q text, p_limit integer default 6) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v_q text := app.addr_norm(left(coalesce(p_q, ''), 120));
begin
  -- a civic number and the start of a street: anything shorter would scan too much of the index for no use
  if length(v_q) < 4 or v_q !~ '^[0-9]' or v_q !~ '[a-z]' then return '[]'::jsonb; end if;
  -- the index range of the prefix, read in index order and stopped at the limit (no sort of every match); the few kept are sorted
  return coalesce((select jsonb_agg(jsonb_build_object('id', 'ca-' || x.id, 'label', app.addr_label(x.num, x.street, x.unit, x.city, x.province, x.postal)) order by x.k)
                     from (select a.*, app.addr_norm(coalesce(a.num, '') || ' ' || a.street || ' ' || coalesce(a.city, '')) as k
                             from ca_addresses a
                            where app.addr_norm(coalesce(a.num, '') || ' ' || a.street || ' ' || coalesce(a.city, '')) like v_q || '%'
                            limit greatest(1, least(coalesce(p_limit, 6), 10))) x), '[]'::jsonb);
end $$;

create or replace function public.server_address_get(p_id text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('id', 'ca-' || a.id, 'label', app.addr_label(a.num, a.street, a.unit, a.city, a.province, a.postal), 'lat', a.lat, 'lng', a.lng,
           'parts', jsonb_build_object('street', btrim(coalesce(a.num, '') || ' ' || a.street), 'unit', coalesce(a.unit, ''), 'city', coalesce(a.city, ''),
                                       'province', a.province, 'postal_code', coalesce(a.postal, ''), 'country', 'Canada'))
    from ca_addresses a
   where p_id ~ '^ca-[0-9]{1,18}$' and a.id = substr(p_id, 4)::bigint
$$;

-- ================================================================ 4. the import
create or replace function public.server_address_import_begin(p_provinces text[], p_run_url text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v integer;
begin
  insert into address_imports (provinces, run_url) values (coalesce(p_provinces, '{}'), left(p_run_url, 300)) returning id into v;
  return jsonb_build_object('id', v, 'db_bytes', pg_database_size(current_database()), 'cap_bytes', (app.settings()).place_db_cap_mb::bigint * 1024 * 1024,
                            'rows', (select count(*) from ca_addresses), 'table_bytes', pg_total_relation_size('ca_addresses'));
end $$;

-- the newest row of a province before its new rows go in: the rows up to it are deleted once the new ones are in
create or replace function public.server_address_province_mark(p_province text) returns bigint
language sql stable security definer set search_path = public, app as $$
  select coalesce(max(id), 0) from ca_addresses where province = upper(p_province)
$$;

-- one range of a province's older rows deleted (the loader calls it until it answers 0 past the mark)
create or replace function public.server_address_prune(p_province text, p_from bigint, p_to bigint) returns integer
language plpgsql security definer set search_path = public, app as $$
declare n integer;
begin
  delete from ca_addresses where id between p_from and p_to and province = upper(p_province);
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.server_address_import_finish(p_id integer, p_status text, p_counts jsonb, p_skipped jsonb) returns void
language sql security definer set search_path = public, app as $$
  update address_imports set status = case when p_status in ('done', 'failed') then p_status else 'done' end,
         counts = coalesce(p_counts, '{}'::jsonb), skipped = coalesce(p_skipped, '{}'::jsonb), finished_at = now()
   where id = p_id
$$;

do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'public' and p.proname = any (array['server_address_search', 'server_address_get', 'server_address_import_begin', 'server_address_province_mark',
              'server_address_prune', 'server_address_import_finish']))
        or (n.nspname = 'app' and p.proname = any (array['addr_label']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
grant execute on function app.addr_norm(text) to service_role;
