-- 0843_hotfix_contact_phone.sql
-- Hotfix (owner, November 8): staff abroad (the Philippines) could not finish their profile: the profile step needs a phone,
-- and the only way to add one was a texted code, which goes to Canadian (and, when allowed, US) mobiles only. A number from
-- anywhere can now be saved as the account's contact number without a code. It is not verified, so it never signs in and
-- never counts as a verified number; a verified number on file is never replaced this way. Audited.
-- SCHEMA_MARKER 0843. No applied migration is edited.

create or replace function app.account_set_contact_phone(p_user uuid, p_phone text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_phone text := app.phone_e164(p_phone);
  u users;
begin
  select * into u from users where id = p_user;
  if u.id is null then raise exception 'Sign in first' using errcode = '42501'; end if;
  if v_phone is null then
    raise exception 'Enter the number with its country code, for example +63 917 123 4567' using errcode = '22023';
  end if;
  if u.phone_verified_at is not null and u.phone is not null and u.phone <> v_phone then
    raise exception 'Your verified number stays on file; change it with a texted code' using errcode = '23514';
  end if;
  if u.phone_verified_at is null then
    update users set phone = v_phone where id = p_user;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
    values (p_user, 'account_contact_phone_set', 'users', p_user::text,
            jsonb_build_object('phone', u.phone), jsonb_build_object('phone', v_phone, 'verified', false, 'migration', '0843'));
  end if;
  return jsonb_build_object('ok', true, 'phone', v_phone);
end $$;

create or replace function public.server_account_set_contact_phone(p_user uuid, p_phone text) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.account_set_contact_phone(p_user, p_phone) $$;

revoke all on function app.account_set_contact_phone(uuid, text) from public, anon, authenticated;
revoke all on function public.server_account_set_contact_phone(uuid, text) from public, anon, authenticated;
grant execute on function app.account_set_contact_phone(uuid, text) to service_role;
grant execute on function public.server_account_set_contact_phone(uuid, text) to service_role;
