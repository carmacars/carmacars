-- 2770: password sign-in pauses for an address after repeated wrong passwords. The site asks before it checks a password
-- (web/src/server/actions/auth.ts): 10 or more failed password sign-ins on one address in the last 15 minutes and the
-- next try is not checked at all; the person is told to wait, to reset the password, or to sign in by phone or Google.
-- The count is the one sign-in security already keeps (sign_in_events, 0466: no address of the visitor is stored), so
-- nothing new is recorded; a correct sign-in does not clear it, the 15 minutes do. Test addresses are never recorded
-- (0466), so they are never paused. The site lets a sign-in through when this cannot be read.
create function app.server_sign_in_allowed(p_email text) returns boolean
language sql stable security definer set search_path = public, app as $$
  select (select count(*) from sign_in_events e
           where not e.ok and e.email = lower(btrim(coalesce(p_email, ''))) and e.at > now() - interval '15 minutes') < 10
$$;
comment on function app.server_sign_in_allowed(text) is 'Sign-in security (2770): false while an address has 10 or more failed password sign-ins in the last 15 minutes.';

create function public.server_sign_in_allowed(p_email text) returns boolean
language sql stable set search_path = public, app as $$ select app.server_sign_in_allowed(p_email) $$;

revoke all on function app.server_sign_in_allowed(text) from public, anon, authenticated;
revoke all on function public.server_sign_in_allowed(text) from public, anon, authenticated;
grant execute on function app.server_sign_in_allowed(text) to service_role;
grant execute on function public.server_sign_in_allowed(text) to service_role;
