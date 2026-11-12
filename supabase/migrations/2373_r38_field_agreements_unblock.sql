-- 2373_r38_field_agreements_unblock.sql (release 38)
-- Owner, Nov 11: field staff said their agreements were not live, so the onboarding gate held them. The Field Staff
-- Agreement needs the driver's licence number, and no record held it, so the agreements job (1060) marked every field hire
-- as waiting (an Admin To do nobody could act on) and retried once a day. Now the staff member gives it themselves:
--   1. staff_profiles.licence_number: entered by the staff member (Welcome, the agreement step; or their field profile).
--      Saving it clears their waiting row, so the agreements job generates and sends the agreement on its next run.
--   2. app.staff_agreement_prepare carries it (staff.licence_number); the agreement fills it in (person-agreements model).
--   3. app.staff_welcome: the agreement step says needs_licence while the in-person agreement waits for it.
--   4. The door: ops_do staff_licence_number_save and the read staff_licence_number (set, last 4), open while the
--      onboarding gate holds the person. The address stays required: Welcome's profile step and the profile ask for it.
--   5. Every waiting row is cleared once, so agreements waiting on anything else are tried again now.
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

-- ================================================================ 1. the number
alter table staff_profiles add column if not exists licence_number text check (licence_number is null or length(licence_number) between 5 and 25);
alter table staff_profiles add column if not exists licence_number_set_at timestamptz;
comment on column staff_profiles.licence_number is 'Driver''s licence number (2373), entered by the staff member for the Field Staff Agreement; read only by the agreement and Admins.';

-- the in-person agreement still waits for the number
create function app.staff_licence_number_needed(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from staff_profiles sp where sp.user_id = p_user and sp.is_active and app.staff_agreement_kind(sp) = 'in_person'
                   and sp.licence_number is null and sp.agreement_waived_at is null and not app.staff_agreement_signed(p_user))
$$;

-- p: {licence_number}. An Ontario number is checked for its shape (A1234-12345-12345); another province's is letters and digits.
create function app.staff_licence_number_save(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v text := upper(regexp_replace(coalesce(p ->> 'licence_number', ''), '[\s]', '', 'g'));
begin
  if not exists (select 1 from staff_profiles where user_id = p_user and is_active) then raise exception 'Not permitted' using errcode = '42501'; end if;
  if v ~ '^[A-Z][0-9]{14}$' then v := substr(v, 1, 5) || '-' || substr(v, 6, 5) || '-' || substr(v, 11, 5); end if;
  if v !~ '^[A-Z0-9][A-Z0-9-]{4,24}$' or v !~ '[0-9]' then
    raise exception 'Write your driver''s licence number as it is on the card, for example A1234-12345-12345' using errcode = '22023';
  end if;
  update staff_profiles set licence_number = v, licence_number_set_at = now() where user_id = p_user;
  -- the agreement waited for it: the job tries again on its next run
  delete from staff_agreement_auto where user_id = p_user and request_id is null;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_user, 'staff_licence_number_save', 'staff_profiles', p_user::text, '{}'::jsonb);
  return jsonb_build_object('ok', true, 'saved', true);
end $$;
revoke all on function app.staff_licence_number_needed(uuid) from public, anon, authenticated;
revoke all on function app.staff_licence_number_save(uuid, jsonb) from public, anon, authenticated;
grant execute on function app.staff_licence_number_needed(uuid) to service_role;
grant execute on function app.staff_licence_number_save(uuid, jsonb) to service_role;

-- ================================================================ 2. the agreement carries it
alter function app.staff_agreement_prepare(uuid, uuid) rename to staff_agreement_prepare_pre2373;
create function app.staff_agreement_prepare(p_by uuid, p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  r jsonb := app.staff_agreement_prepare_pre2373(p_by, p_user);
begin
  return jsonb_set(r, '{staff}', coalesce(r -> 'staff', '{}'::jsonb)
    || jsonb_build_object('licence_number', (select sp.licence_number from staff_profiles sp where sp.user_id = p_user)));
end $$;
select pg_temp.copy_grants('app.staff_agreement_prepare(uuid, uuid)'::regprocedure, 'app.staff_agreement_prepare_pre2373(uuid, uuid)'::regprocedure);
revoke all on function app.staff_agreement_prepare_pre2373(uuid, uuid) from public, anon, authenticated;
grant execute on function app.staff_agreement_prepare_pre2373(uuid, uuid) to service_role;

-- ================================================================ 3. Welcome says so
alter function app.staff_welcome(uuid) rename to staff_welcome_pre2373;
create function app.staff_welcome(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.staff_welcome_pre2373(p_user);
begin
  if v -> 'steps' is null or not app.staff_licence_number_needed(p_user) then return v; end if;
  return v || jsonb_build_object('steps', (select jsonb_agg(case when y ->> 'key' = 'agreement' then y || '{"needs_licence": true}'::jsonb else y end order by n)
                                             from jsonb_array_elements(v -> 'steps') with ordinality t(y, n)));
end $$;
select pg_temp.copy_grants('app.staff_welcome(uuid)'::regprocedure, 'app.staff_welcome_pre2373(uuid)'::regprocedure);
revoke all on function app.staff_welcome_pre2373(uuid) from public, anon, authenticated;
grant execute on function app.staff_welcome_pre2373(uuid) to service_role;

-- ================================================================ 4. the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre2373;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call in ('ops_do', 'field_do', 'va_do') and p_name = 'staff_licence_number_save' then
    perform app.door_begin(p_user, p_aal);
    return app.staff_licence_number_save(p_user, coalesce(p, '{}'::jsonb));
  end if;
  -- the person's own: whether it is given, and its last 4 characters only
  if p_call in ('ops_read', 'field_read', 'va_read') and p_name = 'staff_licence_number' then
    perform app.door_begin(p_user, p_aal);
    return (select jsonb_build_object('set', sp.licence_number is not null, 'last4', right(sp.licence_number, 4)) from staff_profiles sp where sp.user_id = p_user);
  end if;
  return app.door_pre2373(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre2373(uuid, text, text, text, jsonb)'::regprocedure);
revoke all on function app.door_pre2373(uuid, text, text, text, jsonb) from public, anon, authenticated;
grant execute on function app.door_pre2373(uuid, text, text, text, jsonb) to service_role;

-- ================================================================ 5. try every waiting agreement again
delete from staff_agreement_auto where request_id is null;
