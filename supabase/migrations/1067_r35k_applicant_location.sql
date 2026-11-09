-- 1067_r35k_applicant_location.sql
-- Release 35, part K (item 14, docs/changes/2026-11-09-r35-same-rate-plans-location.md): applicants abroad were applying for
-- in-person Sales.
--   1. An in-person role (in-person Sales, field staff) asks where the applicant lives: city, province or state, country;
--      with the phone's country (from its code) and the country of the connection (the IP's country only, never the IP).
--      Outside the service area (Program settings in_person_area_km, 100 km around the office, or the GTA; any country but
--      Canada) the applicant is told in-person work needs the Toronto area and is sent to the Remote Sales application with
--      their details; the in-person application is not taken. A Canadian city the site cannot place is taken and flagged.
--   2. Admin's applicant lists show the location and "Location mismatch" when the phone's country, the connection's country
--      and the stated country disagree; an in-person Sales applicant with a phone or location outside Canada is flagged
--      with Move to Remote Sales (one click: the referral email of 0173).
--   3. Staff: Welcome asks every hire where they live; a Sales hire's work mode follows it (in person only inside the
--      area, remote otherwise). The Hire form chooses Sales remote by default for an applicant outside the area, and
--      one-step Hire refuses in-person Sales for them.
-- No applied migration is edited: public.server_hiring_apply, app.hiring_app_row, app.hire_preview, app.hire_onboard,
-- app.staff_welcome and app.door are wrapped.
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

alter table program_settings
  add column if not exists in_person_area_km integer not null default 100 check (in_person_area_km between 10 and 500),
  add column if not exists in_person_area_cities text[] not null default array['toronto', 'mississauga', 'brampton', 'vaughan', 'markham', 'richmond hill',
    'oakville', 'burlington', 'hamilton', 'pickering', 'ajax', 'whitby', 'oshawa', 'milton', 'newmarket', 'aurora', 'scarborough', 'north york', 'etobicoke',
    'york', 'east york', 'caledon', 'halton hills', 'georgetown', 'bolton', 'stouffville', 'king city', 'uxbridge', 'clarington', 'bowmanville', 'barrie',
    'innisfil', 'bradford', 'grimsby', 'st. catharines', 'niagara falls', 'guelph', 'kitchener', 'waterloo', 'cambridge', 'brantford'];
comment on column program_settings.in_person_area_km is 'In-person roles (1067): the radius around the office (company location; Toronto when unset) inside which an applicant or hire may work in person.';
comment on column program_settings.in_person_area_cities is 'In-person roles (1067): the cities taken as inside the area when the site cannot place a city on the map.';

alter table job_applications
  add column if not exists location_city text check (length(location_city) <= 80),
  add column if not exists location_region text check (length(location_region) <= 80),
  add column if not exists location_country text check (location_country ~ '^[A-Z]{2}$'),
  add column if not exists phone_country text check (phone_country ~ '^[A-Z]{2}$'),
  add column if not exists ip_country text check (ip_country ~ '^[A-Z]{2}$'),
  add column if not exists location_area text check (location_area in ('inside', 'outside', 'unknown'));
comment on column job_applications.ip_country is 'The country of the connection the application came from (1067): the country only, never the address.';
alter table staff_profiles
  add column if not exists location_city text check (length(location_city) <= 80),
  add column if not exists location_country text check (location_country ~ '^[A-Z]{2}$'),
  add column if not exists location_area text check (location_area in ('inside', 'outside', 'unknown'));

-- the country of a phone number from its code (the cases that matter here)
create function app.phone_country_code(p_phone text) returns text
language sql immutable as $$
  select case
    when d ~ '^1' and length(d) = 11 then 'CA'   -- North America: Canada or the US (the area code decides; Canada is assumed)
    when d ~ '^63' then 'PH' when d ~ '^91' then 'IN' when d ~ '^92' then 'PK' when d ~ '^44' then 'GB' when d ~ '^234' then 'NG'
    when d ~ '^254' then 'KE' when d ~ '^27' then 'ZA' when d ~ '^62' then 'ID' when d ~ '^880' then 'BD' when d ~ '^20' then 'EG'
    when d ~ '^971' then 'AE' when d ~ '^966' then 'SA' when d ~ '^964' then 'IQ' when d ~ '^52' then 'MX'
    when length(d) = 10 then 'CA'
    else null end
    from (select regexp_replace(coalesce(p_phone, ''), '\D', '', 'g') d) x
$$;

-- inside the service area: Canada, and a city within the radius of the office (or on the list when it cannot be placed)
create function app.in_person_area(p_city text, p_country text) returns text
language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  v_city text := lower(btrim(coalesce(p_city, '')));
  v_km numeric;
begin
  if upper(coalesce(p_country, '')) <> 'CA' then return 'outside'; end if;
  if v_city = '' then return 'unknown'; end if;
  select min(app.distance_km(coalesce(s.company_latitude, 43.6532), coalesce(s.company_longitude, -79.3832), pl.lat::numeric, pl.lng::numeric)) into v_km
    from places pl where pl.country = 'CA' and lower(pl.name) = v_city;
  if v_km is not null then return case when v_km <= s.in_person_area_km then 'inside' else 'outside' end; end if;
  return case when v_city = any (s.in_person_area_cities) then 'inside' else 'unknown' end;
end $$;

-- the countries disagree (phone, connection, stated)
create function app.location_mismatch(a job_applications) returns boolean
language sql immutable as $$
  select (select count(distinct c) from unnest(array[a.location_country, a.phone_country, a.ip_country]) c where c is not null) > 1
$$;

-- ================================================================ 1. the application
alter function public.server_hiring_apply(jsonb, text) rename to server_hiring_apply_pre1067;
create function public.server_hiring_apply(p jsonb, p_ip text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r hiring_roles;
  s hiring_roles;
  v jsonb;
  v_country text := upper(nullif(btrim(coalesce(p ->> 'location_country', '')), ''));
  v_ip text := upper(nullif(btrim(coalesce(p ->> 'ip_country', '')), ''));
  v_area text;
  a job_applications;
begin
  select * into r from hiring_roles where slug = p ->> 'role' and active;
  if r.id is not null and not r.remote then
    -- the form sends the location (an older link or the API without it: taken, the area unknown, the other signals flag it)
    if p ? 'location_city' and (nullif(btrim(coalesce(p ->> 'location_city', '')), '') is null or v_country is null) then
      return jsonb_build_object('ok', false, 'error', 'invalid', 'errors', jsonb_build_object('location_city', 'Enter the city you live in, and your country.'));
    end if;
    v_area := case when p ? 'location_city' then app.in_person_area(p ->> 'location_city', v_country) else 'unknown' end;
    if v_area = 'outside' then
      select * into s from hiring_roles where active and va_function = 'sales' and (remote or work_mode = 'remote') order by sort_order limit 1;
      return jsonb_build_object('ok', false, 'error', 'outside_area', 'remote_slug', s.slug, 'remote_title', s.title);
    end if;
  end if;
  v := public.server_hiring_apply_pre1067(p, p_ip);
  if coalesce((v ->> 'ok')::boolean, false) then
    update job_applications set location_city = left(nullif(btrim(coalesce(p ->> 'location_city', '')), ''), 80),
           location_region = left(nullif(btrim(coalesce(p ->> 'location_region', '')), ''), 80),
           location_country = case when v_country ~ '^[A-Z]{2}$' then v_country end,
           ip_country = case when v_ip ~ '^[A-Z]{2}$' then v_ip end,
           phone_country = app.phone_country_code(phone), location_area = coalesce(v_area, location_area)
     where id = (select x.id from job_applications x join hiring_roles rr on rr.id = x.role_id
                  where rr.slug = p ->> 'role' and lower(x.email) = lower(btrim(p ->> 'email')) order by x.created_at desc limit 1);
  end if;
  return v;
end $$;
select pg_temp.copy_grants('public.server_hiring_apply(jsonb, text)'::regprocedure, 'public.server_hiring_apply_pre1067(jsonb, text)'::regprocedure);

-- ================================================================ 2. Admin's lists
alter function app.hiring_app_row(job_applications) rename to hiring_app_row_pre1067;
create function app.hiring_app_row(a job_applications) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.hiring_app_row_pre1067(a) || jsonb_build_object(
    'location', nullif(concat_ws(', ', a.location_city, a.location_region, a.location_country), ''), 'phone_country', coalesce(a.phone_country, app.phone_country_code(a.phone)),
    'ip_country', a.ip_country, 'location_area', a.location_area, 'location_mismatch', app.location_mismatch(a),
    'move_remote', r.va_function = 'sales' and not r.remote and a.hired_user_id is null and a.status not in ('referred', 'withdrawn', 'declined', 'rejected')
                   and (coalesce(a.location_country, 'CA') <> 'CA' or coalesce(a.phone_country, app.phone_country_code(a.phone), 'CA') <> 'CA' or a.location_area = 'outside'))
    from hiring_roles r where r.id = a.role_id
$$;
select pg_temp.copy_grants('app.hiring_app_row(job_applications)'::regprocedure, 'app.hiring_app_row_pre1067(job_applications)'::regprocedure);

-- Move to Remote Sales: the referral of 0173 to the remote Sales role
create function app.hiring_move_remote(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  a job_applications := app.hiring_lock(p_by, nullif(p ->> 'id', '')::uuid);
  t hiring_roles;
begin
  select * into t from hiring_roles where active and va_function = 'sales' and (remote or work_mode = 'remote') order by sort_order limit 1;
  if t.id is null then raise exception 'Remote Sales is not open' using errcode = '23514'; end if;
  if a.hired_user_id is not null then raise exception 'This candidate is hired already' using errcode = '23514'; end if;
  update job_applications set status = 'referred', referred_role_id = t.id, decided_at = now(), decided_by = p_by, updated_at = now() where id = a.id returning * into a;
  perform app.hiring_emit('applicant_referred', a, jsonb_build_object('reason_text', 'In-person work needs the Toronto area', 'other_role_title', t.title, 'other_role_summary', t.summary,
    'apply_url', app.hiring_url('/careers/' || t.slug || '/apply?ref=' || a.token || '&src=referral'), 'alt_role_title', '', 'alt_apply_url', ''), 'applicant_referred:' || a.id || ':remote');
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, 'hiring_move_remote', 'job_applications', a.id::text, jsonb_build_object('to', t.slug));
  return app.hiring_app_row(a);
end $$;

-- ================================================================ 3. the hire: the mode follows the location
alter function app.hire_preview(uuid, jsonb) rename to hire_preview_pre1067;
create function app.hire_preview(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  a job_applications;
  v_out boolean;
begin
  select * into a from job_applications where id = nullif(p ->> 'id', '')::uuid;
  v_out := a.location_area = 'outside' or coalesce(a.location_country, 'CA') <> 'CA' or coalesce(a.phone_country, app.phone_country_code(a.phone), 'CA') <> 'CA';
  if v_out and nullif(p ->> 'function', '') is null and exists (select 1 from hiring_roles r where r.id = a.role_id and r.va_function = 'sales') then
    p := p || '{"function": "sales_remote"}';
  end if;
  return app.hire_preview_pre1067(p_by, p) || jsonb_build_object('outside_area', v_out);
end $$;
select pg_temp.copy_grants('app.hire_preview(uuid, jsonb)'::regprocedure, 'app.hire_preview_pre1067(uuid, jsonb)'::regprocedure);

alter function app.hire_onboard(uuid, jsonb) rename to hire_onboard_pre1067;
create function app.hire_onboard(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare a job_applications;
begin
  select * into a from job_applications where id = nullif(p ->> 'id', '')::uuid;
  if p ->> 'function' = 'sales_in_person' and (a.location_area = 'outside' or coalesce(a.location_country, 'CA') <> 'CA') then
    raise exception 'This candidate lives outside the Toronto area: hire them for Sales remote' using errcode = '23514';
  end if;
  return app.hire_onboard_pre1067(p_by, p);
end $$;
select pg_temp.copy_grants('app.hire_onboard(uuid, jsonb)'::regprocedure, 'app.hire_onboard_pre1067(uuid, jsonb)'::regprocedure);

-- Welcome: where do you live; a Sales hire's work mode follows it
create function app.staff_location_save(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_city text := left(nullif(btrim(coalesce(p ->> 'city', '')), ''), 80);
  v_country text := upper(nullif(btrim(coalesce(p ->> 'country', '')), ''));
  v_area text;
  sp staff_profiles;
begin
  if v_city is null or coalesce(v_country, '') !~ '^[A-Z]{2}$' then raise exception 'Enter your city and choose your country' using errcode = '22023'; end if;
  v_area := app.in_person_area(v_city, v_country);
  update staff_profiles set location_city = v_city, location_country = v_country, location_area = v_area,
         sales_work_mode = case when 'sales' = any (functions) then case when v_area = 'inside' then coalesce(sales_work_mode, 'in_person') else 'remote' end else sales_work_mode end
   where user_id = p_user returning * into sp;
  if sp.user_id is null then raise exception 'Staff only' using errcode = '42501'; end if;
  return jsonb_build_object('area', v_area, 'sales_work_mode', (select sales_work_mode from staff_profiles where user_id = p_user));
end $$;

alter function app.staff_welcome(uuid) rename to staff_welcome_pre1067;
create function app.staff_welcome(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.staff_welcome_pre1067(p_user);
  sp staff_profiles;
begin
  select * into sp from staff_profiles where user_id = p_user;
  return jsonb_set(v, '{steps}', coalesce((select jsonb_agg(case when s ->> 'key' = 'profile'
      then s || jsonb_build_object('location', nullif(concat_ws(', ', sp.location_city, sp.location_country), ''), 'done', (s ->> 'done')::boolean and sp.location_city is not null)
      else s end order by o) from jsonb_array_elements(v -> 'steps') with ordinality x(s, o)), v -> 'steps'));
end $$;
select pg_temp.copy_grants('app.staff_welcome(uuid)'::regprocedure, 'app.staff_welcome_pre1067(uuid)'::regprocedure);

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre1067;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'ops_do' and p_name = 'staff_location_save' then
    perform app.door_begin(p_user, p_aal);
    return app.staff_location_save(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  if p_call = 'admin_do' and p_name = 'hiring_move_remote' then
    perform app.door_begin(p_user, p_aal);
    perform app.assert_admin(p_user);
    return app.hiring_move_remote(p_user, coalesce(p, '{}'::jsonb));
  end if;
  return app.door_pre1067(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre1067(uuid, text, text, text, jsonb)'::regprocedure);

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where (n.nspname = 'app' and p.proname = any (array['phone_country_code', 'in_person_area', 'location_mismatch', 'hiring_app_row_pre1067', 'hiring_move_remote',
                     'hire_preview_pre1067', 'hire_onboard_pre1067', 'staff_location_save', 'staff_welcome_pre1067', 'door_pre1067']))
               or (n.nspname = 'public' and p.proname = 'server_hiring_apply_pre1067')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
