-- 3170_r48app_passkeys.sql
-- SCHEMA_MARKER 3170. docs/changes/2026-11-20-r48-native-app.md.
-- Release 48, the native app (apps/carmacars-native, docs/changes/2026-11-20-r48-native-app.md): sign-in with a passkey.
--
-- A passkey is a WebAuthn credential the phone keeps (Face ID, fingerprint or the screen lock opens it). The site keeps
-- only its public key. The server (web/src/server/mobile/passkeys.ts) checks the phone's answer with that key
-- (web/src/lib/auth/webauthn.ts); the database keeps the keys and the one-time challenges and decides what is allowed:
--   - a challenge is random, lasts five minutes and works once;
--   - a person adds a passkey only while signed in, and keeps at most ten;
--   - a passkey signs in only the account it was added to, and a counter that goes backwards is refused (a copied key);
--   - removing the account removes its passkeys (on delete cascade), and "Delete my account" (0390) is unchanged.
-- Nothing here is callable from a browser: the mobile API (/api/m/v1) calls these as the server.

create table if not exists passkeys (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references users (id) on delete cascade,
  credential_id  text not null unique check (credential_id ~ '^[A-Za-z0-9_-]+$' and length(credential_id) between 16 and 1400),
  public_key     jsonb not null,
  alg            integer not null check (alg in (-7, -257)),
  sign_count     bigint not null default 0 check (sign_count >= 0),
  device         text check (length(device) <= 60),
  created_at     timestamptz not null default now(),
  last_used_at   timestamptz
);
create index if not exists passkeys_user_idx on passkeys (user_id);
comment on table passkeys is 'Native app (3170): the public keys of the passkeys a person added in the app. The private key never leaves their phone.';

create table if not exists passkey_challenges (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid references users (id) on delete cascade,
  kind        text not null check (kind in ('register', 'sign_in')),
  challenge   text not null,
  ip          inet,
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null default now() + interval '5 minutes',
  used_at     timestamptz,
  check (kind = 'sign_in' or user_id is not null)
);
create index if not exists passkey_challenges_user_idx on passkey_challenges (user_id);
create index if not exists passkey_challenges_expires_idx on passkey_challenges (expires_at);
comment on table passkey_challenges is 'Native app (3170): one-time WebAuthn challenges (five minutes, used once). Old rows are removed as new ones are made.';

-- ---------------------------------------------------------------- the rules
create or replace function app.passkey_list(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', k.id, 'device', k.device, 'created_at', k.created_at, 'last_used_at', k.last_used_at) order by k.created_at), '[]'::jsonb)
    from passkeys k where k.user_id = p_user
$$;

create or replace function app.passkey_challenge(p_user uuid, p_kind text, p_ip inet default null) returns jsonb
language plpgsql volatile security definer set search_path = public, app as $$
declare
  v_id uuid;
  v_challenge text;
  v_recent integer;
begin
  if p_kind not in ('register', 'sign_in') then raise exception 'Unknown passkey step' using errcode = '22023'; end if;
  if p_kind = 'register' then
    if p_user is null or not exists (select 1 from users where id = p_user) then raise exception 'Sign in first' using errcode = '42501'; end if;
    if (select count(*) from passkeys where user_id = p_user) >= 10 then
      raise exception 'You have ten passkeys already. Remove one first.' using errcode = 'P0001';
    end if;
  end if;
  -- housekeeping, and a limit: thirty challenges in five minutes from one address (or for one person) is not a person
  delete from passkey_challenges where expires_at < now() - interval '1 hour';
  select count(*) into v_recent from passkey_challenges
   where created_at > now() - interval '5 minutes'
     and ((p_ip is not null and ip = p_ip) or (p_user is not null and user_id = p_user));
  if v_recent >= 30 then raise exception 'Too many tries. Wait a few minutes, then try again.' using errcode = 'P0001'; end if;
  v_challenge := translate(encode(sha256((gen_random_uuid()::text || gen_random_uuid()::text || clock_timestamp()::text)::bytea), 'base64'), '+/=', '-_');
  insert into passkey_challenges (user_id, kind, challenge, ip)
  values (case when p_kind = 'register' then p_user end, p_kind, v_challenge, p_ip)
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'challenge', v_challenge,
    'credentials', case when p_kind = 'register'
      then coalesce((select jsonb_agg(credential_id) from passkeys where user_id = p_user), '[]'::jsonb) else '[]'::jsonb end);
end $$;

/** The open challenge, for the server to check the phone's answer against. Null: unknown, expired or used. */
create or replace function app.passkey_challenge_read(p_id uuid, p_kind text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('challenge', c.challenge, 'user_id', c.user_id)
    from passkey_challenges c where c.id = p_id and c.kind = p_kind and c.used_at is null and c.expires_at > now()
$$;

create or replace function app.passkey_register(p_user uuid, p_challenge uuid, p jsonb) returns jsonb
language plpgsql volatile security definer set search_path = public, app as $$
declare
  v_cred text := p->>'credential_id';
  v_alg integer := (p->>'alg')::integer;
begin
  update passkey_challenges set used_at = now()
   where id = p_challenge and kind = 'register' and user_id = p_user and used_at is null and expires_at > now();
  if not found then raise exception 'That took too long. Try adding the passkey again.' using errcode = 'P0001'; end if;
  if v_cred is null or jsonb_typeof(p->'public_key') is distinct from 'object' or v_alg is null then
    raise exception 'The phone gave no passkey' using errcode = '22023';
  end if;
  if (select count(*) from passkeys where user_id = p_user) >= 10 then
    raise exception 'You have ten passkeys already. Remove one first.' using errcode = 'P0001';
  end if;
  if exists (select 1 from passkeys where credential_id = v_cred) then
    raise exception 'This passkey is already added.' using errcode = 'P0001';
  end if;
  insert into passkeys (user_id, credential_id, public_key, alg, sign_count, device)
  values (p_user, v_cred, p->'public_key', v_alg, greatest(coalesce((p->>'sign_count')::bigint, 0), 0), nullif(left(btrim(coalesce(p->>'device', '')), 60), ''));
  return app.passkey_list(p_user);
end $$;

/** The passkey a sign-in names, with its key (the server checks the signature before app.passkey_used). */
create or replace function app.passkey_lookup(p_credential text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('id', k.id, 'user_id', k.user_id, 'public_key', k.public_key, 'alg', k.alg, 'sign_count', k.sign_count)
    from passkeys k where k.credential_id = p_credential
$$;

/** After the signature checked out: the challenge is spent and the counter moves. Returns the account that signs in. */
create or replace function app.passkey_used(p_challenge uuid, p_credential text, p_sign_count bigint) returns uuid
language plpgsql volatile security definer set search_path = public, app as $$
declare
  k passkeys;
begin
  select * into k from passkeys where credential_id = p_credential for update;
  if not found then raise exception 'This passkey is not known. Sign in another way.' using errcode = '42501'; end if;
  update passkey_challenges set used_at = now()
   where id = p_challenge and kind = 'sign_in' and used_at is null and expires_at > now();
  if not found then raise exception 'That took too long. Try again.' using errcode = 'P0001'; end if;
  -- a counter that does not move forward (when the phone counts at all) means the key was copied
  if (k.sign_count > 0 or coalesce(p_sign_count, 0) > 0) and coalesce(p_sign_count, 0) <= k.sign_count then
    raise exception 'This passkey was refused. Sign in another way and add it again.' using errcode = '42501';
  end if;
  update passkeys set sign_count = greatest(coalesce(p_sign_count, 0), sign_count), last_used_at = now() where id = k.id;
  return k.user_id;
end $$;

create or replace function app.passkey_remove(p_user uuid, p_id uuid) returns jsonb
language plpgsql volatile security definer set search_path = public, app as $$
begin
  delete from passkeys where id = p_id and user_id = p_user;
  if not found then raise exception 'Passkey not found' using errcode = 'P0002'; end if;
  return app.passkey_list(p_user);
end $$;

-- ---------------------------------------------------------------- the server's wrappers
create or replace function public.server_passkeys(p_user uuid) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.passkey_list(p_user) $$;
create or replace function public.server_passkey_challenge(p_user uuid, p_kind text, p_ip inet default null) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.passkey_challenge(p_user, p_kind, p_ip) $$;
create or replace function public.server_passkey_challenge_read(p_id uuid, p_kind text) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.passkey_challenge_read(p_id, p_kind) $$;
create or replace function public.server_passkey_register(p_user uuid, p_challenge uuid, p jsonb) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.passkey_register(p_user, p_challenge, p) $$;
create or replace function public.server_passkey_lookup(p_credential text) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.passkey_lookup(p_credential) $$;
create or replace function public.server_passkey_used(p_challenge uuid, p_credential text, p_sign_count bigint) returns uuid
language sql volatile security invoker set search_path = public, app as $$ select app.passkey_used(p_challenge, p_credential, p_sign_count) $$;
create or replace function public.server_passkey_remove(p_user uuid, p_id uuid) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.passkey_remove(p_user, p_id) $$;

-- ---------------------------------------------------------------- row-level security and privileges
alter table passkeys enable row level security;
alter table passkey_challenges enable row level security;
drop policy if exists admin_all on passkeys;
create policy admin_all on passkeys for all to authenticated using (app.is_admin()) with check (app.is_admin());
drop policy if exists admin_all on passkey_challenges;
create policy admin_all on passkey_challenges for all to authenticated using (app.is_admin()) with check (app.is_admin());
drop trigger if exists audit_passkeys on passkeys;
create trigger audit_passkeys after insert or delete on passkeys for each row execute function app.audit_row();
revoke all on passkeys, passkey_challenges from anon, authenticated;
grant select on passkeys, passkey_challenges to authenticated;   -- admins only, by policy
grant all on passkeys, passkey_challenges to service_role;

do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['passkey_list', 'passkey_challenge', 'passkey_challenge_read', 'passkey_register',
              'passkey_lookup', 'passkey_used', 'passkey_remove']))
        or (n.nspname = 'public' and p.proname = any (array['server_passkeys', 'server_passkey_challenge', 'server_passkey_challenge_read',
              'server_passkey_register', 'server_passkey_lookup', 'server_passkey_used', 'server_passkey_remove']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
