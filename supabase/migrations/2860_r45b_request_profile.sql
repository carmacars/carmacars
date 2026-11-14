-- 2860 (release 45, part B): a request fills itself from the renter's profile.
--
-- A signed-in renter's booking request filled only the phone and the email. It now fills everything the account holds:
-- the name, the date of birth, the licence (class, issuer, number and expiry), the additional drivers named before and
-- the contact channel; the address and the licence are shown with a flag when they are out of date. Staff picking an
-- existing renter on Send an offer or Add a rental get the same profile.
--   1. renters.address_updated_at: when the home address last changed (kept by a trigger; the ones on file start at the
--      record's last update). program_settings.profile_address_max_months (12): an address older than that is flagged
--      for the renter to confirm or update.
--   2. app.renter_profile_fill(renter, full): the profile as the forms use it. The renter's own browser gets only the
--      last 4 characters of the licence number; staff get it whole (as the renter search already shows it).
--   3. public.server_request_profile(user): the signed-in renter's own profile, for the server only (the service role);
--      nothing for a person who is not signed in or has no renter record.
--   4. ops_read renter_profile_fill {renter}: staff who make offers or add rentals (an Admin, customer service, Sales).
-- No applied migration is edited: the door is wrapped (_pre2860).
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

-- ================================================================ 1. the address's age and the rule
alter table renters add column if not exists address_updated_at timestamptz;
comment on column renters.address_updated_at is 'r45 (2860): when the home address last changed (a trigger keeps it). Older than program_settings.profile_address_max_months: the request form asks the renter to confirm it.';
update renters set address_updated_at = updated_at where address_updated_at is null and nullif(btrim(coalesce(address_line1, '')), '') is not null;

create function app.renter_address_touched() returns trigger
language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    if nullif(btrim(coalesce(new.address_line1, '')), '') is not null and new.address_updated_at is null then new.address_updated_at := now(); end if;
  elsif (new.address_line1, new.address_line2, new.city, new.province, new.postal_code, new.country)
        is distinct from (old.address_line1, old.address_line2, old.city, old.province, old.postal_code, old.country) then
    new.address_updated_at := now();
  end if;
  return new;
end $$;
create trigger renters_address_touched before insert or update on renters for each row execute function app.renter_address_touched();

alter table program_settings add column if not exists profile_address_max_months integer not null default 12
  check (profile_address_max_months between 1 and 120);
comment on column program_settings.profile_address_max_months is 'r45 (2860): a renter''s home address older than this many months is flagged on the request form for them to confirm or update.';

-- ================================================================ 2. the profile
-- "Mary Ann Smith": first "Mary Ann", last "Smith" (one word: first only)
create function app.name_parts(p_name text) returns jsonb
language sql immutable as $$
  select case when position(' ' in n) = 0 then jsonb_build_object('first', n, 'last', '')
              else jsonb_build_object('first', btrim(regexp_replace(n, '\s+\S+$', '')), 'last', substring(n from '(\S+)$')) end
    from (select btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g')) n) x
$$;

create function app.renter_profile_fill(p_renter uuid, p_full boolean default false) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'renter_id', r.id,
    'legal_name', r.legal_name,
    'first', app.name_parts(r.legal_name) ->> 'first',
    'last', app.name_parts(r.legal_name) ->> 'last',
    'date_of_birth', coalesce(r.date_of_birth, d.date_of_birth),
    'email', coalesce(nullif(btrim(r.email), ''), u.email),
    'mobile', coalesce(nullif(btrim(r.mobile), ''), u.phone),
    'notify_channel', coalesce(u.notify_channel, r.notify_channel),
    'address', case when nullif(btrim(coalesce(r.address_line1, '')), '') is not null then jsonb_build_object(
        'line1', r.address_line1, 'line2', r.address_line2, 'city', r.city, 'province', r.province, 'postal_code', r.postal_code,
        'country', r.country, 'updated_at', r.address_updated_at) end,
    'licence', case when d.id is not null and coalesce(d.licence_class, d.licence_number, d.licence_issuer) is not null then jsonb_build_object(
        'class', d.licence_class, 'issuer', d.licence_issuer, 'expiry', d.licence_expiry,
        'number', case when p_full then d.licence_number end,
        'number_end', case when d.licence_number is not null then right(regexp_replace(d.licence_number, '[^A-Za-z0-9]', '', 'g'), 4) end) end,
    'drivers', coalesce((select jsonb_agg(jsonb_build_object('full_name', x.full_name, 'first', app.name_parts(x.full_name) ->> 'first', 'last', app.name_parts(x.full_name) ->> 'last',
                           'date_of_birth', x.date_of_birth, 'email', x.email, 'licence_class', x.licence_class) order by x.updated_at desc)
                          from (select distinct on (lower(btrim(o.full_name))) o.* from drivers o
                                 where o.renter_id = r.id and not o.is_account_holder and nullif(btrim(o.full_name), '') is not null
                                 order by lower(btrim(o.full_name)), o.updated_at desc) x), '[]'::jsonb),
    'stale', jsonb_build_object(
      'licence_expired', d.licence_expiry is not null and d.licence_expiry < app.today(),
      'address_old', r.address_updated_at is not null and r.address_updated_at < now() - make_interval(months => s.profile_address_max_months),
      'address_max_months', s.profile_address_max_months))
    from renters r
    left join users u on u.id = r.user_id
    left join lateral (select * from drivers x where x.renter_id = r.id and x.is_account_holder order by x.updated_at desc limit 1) d on true
    cross join lateral (select (app.settings()).profile_address_max_months) s(profile_address_max_months)
   where r.id = p_renter
$$;
comment on function app.renter_profile_fill(uuid, boolean) is 'r45 (2860): the renter''s profile as the request and the staff forms fill it: name, date of birth, contact, channel, address, licence (the number whole only for staff), the additional drivers named before, and what is out of date.';
revoke all on function app.renter_profile_fill(uuid, boolean) from public, anon, authenticated;
grant execute on function app.renter_profile_fill(uuid, boolean) to service_role;
revoke all on function app.name_parts(text) from public, anon, authenticated;
grant execute on function app.name_parts(text) to service_role;

-- ================================================================ 3. the signed-in renter's own
create function public.server_request_profile(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.renter_profile_fill(r.id, false)
    from renters r where p_user is not null and r.user_id = p_user and r.merged_into is null and not r.is_blocked
   limit 1
$$;
comment on function public.server_request_profile(uuid) is 'r45 (2860): the signed-in renter''s profile for their booking request (the server, as the service role, with the signed-in person''s id). Null for anyone without a renter record.';
revoke all on function public.server_request_profile(uuid) from public, anon, authenticated;
grant execute on function public.server_request_profile(uuid) to service_role;

-- ================================================================ 4. staff picking a renter
create function app.renter_profile_staff(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v_id uuid := nullif(p ->> 'renter', '')::uuid;
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'sales')) then raise exception 'Not permitted' using errcode = '42501'; end if;
  if v_id is null or not exists (select 1 from renters r where r.id = v_id) then raise exception 'Renter not found' using errcode = 'P0002'; end if;
  return app.renter_profile_fill(v_id, true);
end $$;
revoke all on function app.renter_profile_staff(uuid, jsonb) from public, anon, authenticated;
grant execute on function app.renter_profile_staff(uuid, jsonb) to service_role;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre2860;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'ops_read' and p_name = 'renter_profile_fill' then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return app.renter_profile_staff(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre2860(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre2860(uuid, text, text, text, jsonb)'::regprocedure);
revoke all on function app.door_pre2860(uuid, text, text, text, jsonb) from public, anon, authenticated;
grant execute on function app.door_pre2860(uuid, text, text, text, jsonb) to service_role;
