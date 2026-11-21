-- 3400 (release 48, pre-deploy security audit; docs/security/audit-2026-11-r48.md). SCHEMA_MARKER 3400.
-- 1. The native app's sign-out ends its access token at once. The app's tokens are checked with the project's public
--    keys (no call to the sign-in service), so until now a token stayed good until it expired (up to an hour) after
--    "Sign out". The mobile API keeps what was signed out (the token's hash, and its sign-in session) until the token
--    could no longer be used anyway, and refuses it (web/src/server/mobile/auth.ts).
-- 2. The tracker ingest checks the rate before it records the signature: a request refused for the rate (429) can be
--    sent again as it was (a vendor's HTTP push retries the same signed body) instead of being refused as a replay.
-- 3. Every security definer function in public and app searches pg_temp last. Without it PostgreSQL searches the
--    session's temporary schema FIRST for tables, so a session that may create temporary tables could put its own
--    table in front of one a definer function reads. No browser session can run DDL here, so this closes a path that
--    is not open today; the test (99_r48sec_security) keeps every new definer function to the rule.
-- 4. Password sign-in is limited by address too: 30 tries in 15 minutes from one address (website and app). Until now
--    only by the email tried (2770), so one address could try one password on many accounts. With no address, all such
--    tries share one count (the limit is never skipped).

-- ---------------------------------------------------------------- 1. signed-out bearer tokens
create table revoked_bearers (
  key         text primary key check (key ~ '^(t:[0-9a-f]{64}|s:[0-9a-f-]{36})$'),
  revoked_at  timestamptz not null default now(),
  expires_at  timestamptz not null
);
create index revoked_bearers_expires_idx on revoked_bearers (expires_at);
comment on table revoked_bearers is 'Security audit r48 (3400): the native app''s signed-out access tokens (t: the SHA-256 of the token) and sign-in sessions (s: the session id), refused by /api/m/v1 until expires_at. No token itself is kept.';
alter table revoked_bearers enable row level security;
create policy admin_all on revoked_bearers for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on revoked_bearers from anon, authenticated;
grant all on revoked_bearers to service_role;

create function public.server_bearer_revoke(p_keys text[], p_until timestamptz) returns void
language plpgsql volatile security definer set search_path = public, app, pg_temp as $$
begin
  delete from revoked_bearers where expires_at < now();
  insert into revoked_bearers (key, expires_at)
  select k, least(greatest(p_until, now() + interval '5 minutes'), now() + interval '2 days')
    from unnest(p_keys) k where k ~ '^(t:[0-9a-f]{64}|s:[0-9a-f-]{36})$'
  on conflict (key) do update set expires_at = greatest(revoked_bearers.expires_at, excluded.expires_at);
end $$;

create function public.server_bearer_revoked(p_keys text[]) returns boolean
language sql stable security definer set search_path = public, app, pg_temp as $$
  select exists (select 1 from revoked_bearers where key = any (p_keys) and expires_at > now())
$$;
revoke all on function public.server_bearer_revoke(text[], timestamptz), public.server_bearer_revoked(text[]) from public, anon, authenticated;
grant execute on function public.server_bearer_revoke(text[], timestamptz), public.server_bearer_revoked(text[]) to service_role;

-- ---------------------------------------------------------------- 2. the tracker ingest: the rate before the replay record
create or replace function public.server_tracker_ingest_signed(p jsonb, p_sig text, p_ts bigint) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare s tracker_settings := app.tracker_settings();
begin
  if p_sig is null or p_sig !~ '^[0-9a-f]{64}$' then return jsonb_build_object('refused', 'signature'); end if;
  delete from app.tracker_ingest_seen where at < now() - interval '10 minutes';
  if exists (select 1 from app.tracker_ingest_seen where sig = p_sig) then return jsonb_build_object('refused', 'replay'); end if;
  if not app.rate_limit('tracker_ingest', s.ingest_per_minute, interval '1 minute') then return jsonb_build_object('refused', 'rate'); end if;
  begin
    insert into app.tracker_ingest_seen (sig) values (p_sig);
  exception when unique_violation then
    return jsonb_build_object('refused', 'replay');
  end;
  return app.tracker_ingest(p);
end $$;

-- ---------------------------------------------------------------- 4. password sign-in, by address
create function public.server_sign_in_ip_allowed(p_ip text) returns boolean
language sql volatile security definer set search_path = public, app, pg_temp as $$
  select app.rate_limit('sign_in:ip:' || coalesce(nullif(btrim(p_ip), ''), 'none'), 30, interval '15 minutes')
$$;
revoke all on function public.server_sign_in_ip_allowed(text) from public, anon, authenticated;
grant execute on function public.server_sign_in_ip_allowed(text) to service_role;

-- ---------------------------------------------------------------- 3. pg_temp last in every definer function
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig, substr(c, length('search_path=') + 1) as path
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace, unnest(p.proconfig) c
     where p.prosecdef and n.nspname in ('public', 'app') and c like 'search_path=%' and c !~ '\mpg_temp\M'
  loop
    execute format('alter routine %s set search_path = %s, pg_temp', f.sig, f.path);
  end loop;
end $$;
