-- 2460_r40_caller_mobile.sql
-- Release 40 hotfix (the owner, Nov 12: "the sales person caller should give u a pop up for a phone number if no phone
-- number is saved on file for a sales person"; "whenever he tries to put his phone number in, it waits for a code and then
-- he never gets it"). The site's Call button rings the staff member's own mobile first (0970), and a staff member without
-- one on file was refused with an error. Now:
--   1. app.server_twilio_call_start answers {ok: false, need_phone: true} for a staff member with no mobile on file (the
--      Call button then asks for it in a pop-up) instead of raising; with a mobile it is the 0970 start, plus ok: true.
--   2. app.staff_set_call_phone saves the staff member's own Canadian or US mobile from that pop-up, without a texted code
--      (the call itself rings it). Not verified: it never signs in, and a verified number on file is never replaced.
--      Audited.
-- No applied migration is edited.
create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

-- ================================================================ 1. the caller's own mobile, from the Call button's pop-up
create or replace function app.staff_set_call_phone(p_user uuid, p_phone text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v text := app.phone_e164(p_phone);
  u users;
begin
  select * into u from users where id = p_user;
  if u.id is null or u.status <> 'active'
     or not exists (select 1 from user_roles r where r.user_id = p_user and r.role::text in ('admin', 'va', 'field')) then
    raise exception 'Sign in as staff first' using errcode = '42501';
  end if;
  if v is null or coalesce(app.phone_country(v), '') not in ('CA', 'US') then
    raise exception 'Enter your Canadian or US mobile number, 10 digits, for example (647) 555-0123' using errcode = '22023';
  end if;
  if v is not distinct from app.phone_our_number() then
    raise exception 'That is the CarmaCars number: enter your own mobile' using errcode = '22023';
  end if;
  if u.phone_verified_at is not null and u.phone is not null and u.phone <> v then
    raise exception 'Your verified number stays on file; change it on your profile with a texted code' using errcode = '23514';
  end if;
  if u.phone is distinct from v then
    update users set phone = v where id = p_user;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
    values (p_user, 'staff_call_phone_set', 'users', p_user::text,
            jsonb_build_object('phone', u.phone), jsonb_build_object('phone', v, 'verified', u.phone_verified_at is not null, 'migration', '2460'));
  end if;
  return jsonb_build_object('ok', true, 'phone', v, 'display', app.phone_display(v));
end $$;

create or replace function public.server_staff_set_call_phone(p_user uuid, p_phone text) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.staff_set_call_phone(p_user, p_phone) $$;
revoke all on function app.staff_set_call_phone(uuid, text) from public, anon, authenticated;
revoke all on function public.server_staff_set_call_phone(uuid, text) from public, anon, authenticated;
grant execute on function app.staff_set_call_phone(uuid, text) to service_role;
grant execute on function public.server_staff_set_call_phone(uuid, text) to service_role;

-- ================================================================ 2. a call by a staff member with no mobile on file asks for it
alter function app.server_twilio_call_start(jsonb) rename to server_twilio_call_start_pre2460;
create function app.server_twilio_call_start(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_user uuid := nullif(p ->> 'user_id', '')::uuid;
begin
  if v_user is not null
     and exists (select 1 from users u join user_roles r on r.user_id = u.id where u.id = v_user and u.status = 'active' and r.role::text in ('admin', 'va', 'field'))
     and (select app.phone_e164(u.phone) from users u where u.id = v_user) is null then
    return jsonb_build_object('ok', false, 'need_phone', true,
      'message', 'Add your mobile number first: the call rings your phone, then connects the customer.');
  end if;
  return app.server_twilio_call_start_pre2460(p) || jsonb_build_object('ok', true);
end $$;
select pg_temp.copy_grants('app.server_twilio_call_start(jsonb)'::regprocedure, 'app.server_twilio_call_start_pre2460(jsonb)'::regprocedure);
revoke all on function app.server_twilio_call_start_pre2460(jsonb) from public, anon, authenticated;
grant execute on function app.server_twilio_call_start_pre2460(jsonb) to service_role;
