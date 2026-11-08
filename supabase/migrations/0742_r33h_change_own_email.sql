-- 0742: everyone can change their own sign-in email from their profile (release 33 part H, docs/changes/2026-11-07-r33-finishing.md, item 5).
--
-- The sign-in service does the confirming (its email change flow, the same /auth/callback links as every other sign-in link): the person gives the new
-- address, the service emails a confirmation link to the new address and one to the old address (secure email change: the old address is told, and the
-- change takes effect only once the links are opened), and the address on the sign-in does not change before that. These two functions are the database
-- side, called by the website with the service role:
--   app.account_email_change_check: before asking the service, says whether the address can be asked for (valid, different, not another account's);
--   app.account_email_changed: after the link is confirmed (the callback saw the sign-in hold the new address), the contact records follow it (the tables' own history triggers record it):
--   the account (users), and the renter, owner, investor and account-holder driver records of that account. Staff and field staff have the account only.
-- The old rule "your account already has a confirmed email: call or message us" (app.account_set_email, the first email of an account made by phone)
-- now points to the profile. An Admin can still change an email from the record (renter_edit); nothing there changes.
-- No applied migration is edited.

create function app.account_email_change_check(p_user uuid, p_email text) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v text := lower(btrim(coalesce(p_email, '')));
  u users;
begin
  if v !~ '^[^@\s]+@[^@\s]+\.[^@\s]{2,}$' or length(v) > 200 then
    return jsonb_build_object('ok', false, 'error', 'invalid', 'message', 'Enter an email address like name@example.com.');
  end if;
  select * into u from users where id = p_user;
  if u.id is null then return jsonb_build_object('ok', false, 'error', 'no_account', 'message', 'Sign in first.'); end if;
  if lower(coalesce(u.email, '')) = v then
    return jsonb_build_object('ok', false, 'error', 'same', 'message', 'That is already your email.');
  end if;
  if exists (select 1 from users z where lower(z.email) = v and z.id <> u.id) then
    return jsonb_build_object('ok', false, 'error', 'email_taken', 'message', 'This email is already used by another account. Sign in with it instead, or use another email.');
  end if;
  return jsonb_build_object('ok', true, 'email', v, 'old_email', u.email);
end $$;

create function app.account_email_changed(p_user uuid, p_email text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v text := lower(btrim(coalesce(p_email, '')));
  u users;
  v_old text;
begin
  if v !~ '^[^@\s]+@[^@\s]+\.[^@\s]{2,}$' then return jsonb_build_object('ok', false, 'reason', 'invalid'); end if;
  select * into u from users where id = p_user for update;
  if u.id is null then return jsonb_build_object('ok', false, 'reason', 'no_record'); end if;
  if lower(coalesce(u.email, '')) = v then return jsonb_build_object('ok', true, 'changed', false); end if;
  if exists (select 1 from users z where lower(z.email) = v and z.id <> u.id) then return jsonb_build_object('ok', false, 'reason', 'email_taken'); end if;
  v_old := u.email;
  update users set email = v, email_verified_at = now() where id = u.id;
  update renters set email = v where user_id = u.id;
  update owners set email = v where user_id = u.id;
  update investors set email = v where user_id = u.id;
  update drivers set email = v where user_id = u.id and is_account_holder;
  return jsonb_build_object('ok', true, 'changed', true, 'old_email', v_old);
end $$;

create function public.server_account_email_change_check(p_user uuid, p_email text) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.account_email_change_check(p_user, p_email) $$;
create function public.server_account_email_changed(p_user uuid, p_email text) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.account_email_changed(p_user, p_email) $$;
do $$
declare f regprocedure;
begin
  foreach f in array array['app.account_email_change_check(uuid, text)'::regprocedure, 'app.account_email_changed(uuid, text)'::regprocedure,
                           'public.server_account_email_change_check(uuid, text)'::regprocedure, 'public.server_account_email_changed(uuid, text)'::regprocedure] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;

-- the first email of an account made by phone: once it is confirmed, the profile changes it
do $$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'app' and p.proname = 'account_set_email';
  v_new := replace(v_def, 'Your account already has a confirmed email. To change it, call or message us.', 'Your account already has a confirmed email. To change it, use Change my email on your profile.');
  if v_new = v_def then raise exception '0742: the text in app.account_set_email was not found'; end if;
  execute v_new;
end $$;
