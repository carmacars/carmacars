-- 3196 (release 48, part FE; docs/changes/2026-11-20-r48-fees-evidence-hiring.md): a staff agreement that waits for
-- something says so to the person, where they sign.
--
-- The owner sat with Jamal (Sales and Field): his sign page said "Nothing is waiting for your signature". The agreements job
-- (web/src/server/staff-agreement-auto.ts) had recorded what was missing (his driver's licence number) and sent nothing.
-- 1. app.staff_agreement_needs: what the person's agreement waits for, in words, split into what they give (licence number,
--    home address) and what CarmaCars adds (wage, start date, ...), and whether their home address needs confirming.
--    Read on /staff/welcome and on every sign page (ops_read staff_agreement_needs); saving there makes and sends the
--    agreement at once (the site runs the job for that person; no waiting for the cron).
-- 2. The home address of in-person staff (the in-person agreement, or Sales in person) is checked to be in Ontario (an
--    Ontario postal code K, L, M, N or P, or ", ON"); another place is saved and flagged: the person is asked to confirm it
--    (the data check pop-up, 3197; confirm_outside_ontario), kept in staff_profiles.home_address_outside_ok_at.
--    Jamal's was in Pawtucket, RI.
-- 3. Saving the address clears the agreement's waiting row, as saving the licence number does (2373).
-- No applied migration is edited: app.staff_home_address_save and app.door are wrapped (_pre3196).
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

alter table staff_profiles add column if not exists home_address_outside_ok_at timestamptz;
comment on column staff_profiles.home_address_outside_ok_at is 'An in-person staff member confirmed a home address outside Ontario (3196); flagged to the Admins.';

-- an address in Ontario: an Ontario postal code (K, L, M, N, P) or the province written
create function app.address_in_ontario(p_address text, p_postal text) returns boolean
language sql immutable as $$
  select upper(regexp_replace(coalesce(p_postal, ''), '\s', '', 'g')) ~ '^[KLMNP][0-9][A-Z][0-9][A-Z][0-9]$'
      or (coalesce(p_postal, '') = '' and coalesce(p_address, '') ~* '(,|\s)(ON|Ontario)(\s|,|$)')
$$;

-- in person: the in-person agreement, or Sales in person
create function app.staff_in_person(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from staff_profiles sp where sp.user_id = p_user
                   and (app.staff_agreement_kind(sp) = 'in_person' or coalesce(sp.sales_work_mode, '') = 'in_person'))
$$;

create function app.staff_address_flag(p_user uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select case when app.staff_in_person(sp.user_id) and nullif(btrim(coalesce(sp.home_address, '')), '') is not null
                   and not app.address_in_ontario(sp.home_address, sp.home_postal_code) and sp.home_address_outside_ok_at is null
              then 'Your home address is not in Ontario, but you work in person in Toronto: correct it, or confirm it is right' end
    from staff_profiles sp where sp.user_id = p_user
$$;

-- what the person's agreement waits for
create function app.staff_agreement_needs(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  sp staff_profiles;
  a staff_agreement_auto;
  v_missing text[];
  v_mine jsonb := '[]'::jsonb;
  v_theirs text[] := '{}';
  m text;
begin
  select * into sp from staff_profiles where user_id = p_user;
  if sp.user_id is null or sp.agreement_waived_at is not null or app.staff_agreement_signed(p_user) then
    return jsonb_build_object('waiting', false, 'mine', '[]'::jsonb, 'theirs', '[]'::jsonb);
  end if;
  select * into a from staff_agreement_auto where user_id = p_user;
  v_missing := coalesce(a.missing, '{}');
  if app.staff_agreement_kind(sp) = 'in_person' and sp.licence_number is null then v_mine := v_mine || '[{"key": "licence", "label": "Driver''s licence number"}]'::jsonb; end if;
  if nullif(btrim(coalesce(sp.home_address, '')), '') is null or nullif(btrim(coalesce(sp.home_postal_code, '')), '') is null then
    v_mine := v_mine || '[{"key": "address", "label": "Home address"}]'::jsonb;
  end if;
  foreach m in array v_missing loop
    if m !~* '(licence|home address)' then v_theirs := v_theirs || m; end if;
  end loop;
  return jsonb_build_object('waiting', jsonb_array_length(v_mine) > 0 or cardinality(v_theirs) > 0, 'mine', v_mine, 'theirs', to_jsonb(v_theirs),
    'kind', app.staff_agreement_kind(sp), 'in_person', app.staff_in_person(p_user), 'error', a.last_error, 'address_flag', app.staff_address_flag(p_user),
    'sent', exists (select 1 from sign_requests r where r.staff_user_id = p_user and r.doc_type = 'staff_agreement' and r.status = 'sent'));
end $$;

-- the address: in Ontario for in-person staff, or confirmed; the agreement is tried again
alter function app.staff_home_address_save(uuid, jsonb) rename to staff_home_address_save_pre3196;
create function app.staff_home_address_save(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v jsonb;
  v_addr text := regexp_replace(btrim(coalesce(p ->> 'home_address', '')), '\s+', ' ', 'g');
  v_postal text := upper(regexp_replace(btrim(coalesce(p ->> 'home_postal_code', '')), '\s+', ' ', 'g'));
  v_ok boolean := coalesce((p ->> 'confirm_outside_ontario')::boolean, false);
begin
  -- an address outside Ontario of in-person staff is saved and flagged (the data check asks them to confirm it, 3197)
  v := app.staff_home_address_save_pre3196(p_user, p - 'confirm_outside_ontario');
  update staff_profiles set home_address_outside_ok_at = case when app.address_in_ontario(v_addr, v_postal) then null when v_ok then now() else home_address_outside_ok_at end
   where user_id = p_user;
  delete from staff_agreement_auto where user_id = p_user and request_id is null;
  return v;
end $$;
select pg_temp.copy_grants('app.staff_home_address_save(uuid, jsonb)'::regprocedure, 'app.staff_home_address_save_pre3196(uuid, jsonb)'::regprocedure);

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre3196;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'ops_read' and p_name = 'staff_agreement_needs' then
    perform app.door_begin(p_user, p_aal);
    return app.staff_agreement_needs(p_user);
  end if;
  return app.door_pre3196(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre3196(uuid, text, text, text, jsonb)'::regprocedure);

revoke all on function app.address_in_ontario(text, text), app.staff_in_person(uuid), app.staff_address_flag(uuid), app.staff_agreement_needs(uuid),
  app.staff_home_address_save_pre3196(uuid, jsonb), app.door_pre3196(uuid, text, text, text, jsonb) from public, anon, authenticated;
grant execute on function app.address_in_ontario(text, text), app.staff_in_person(uuid), app.staff_address_flag(uuid), app.staff_agreement_needs(uuid),
  app.staff_home_address_save_pre3196(uuid, jsonb), app.door_pre3196(uuid, text, text, text, jsonb) to service_role;
