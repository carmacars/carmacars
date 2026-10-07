-- Local test shim. NOT a migration and never applied to Supabase.
-- Supabase provides the auth schema and auth.uid(); plain PostgreSQL does not.
-- This file gives a fresh local database the same two things, plus a test login helper.

create schema if not exists auth;

-- Same contract as Supabase: the signed-in user's id comes from the request's JWT claims.
create or replace function auth.uid() returns uuid
language sql stable as $$
  select nullif(
    coalesce(current_setting('request.jwt.claim.sub', true),
             (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')),
    '')::uuid
$$;

-- Supabase's three API roles, with the access to the auth schema that Supabase gives them.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin bypassrls; end if;
end $$;
grant usage on schema auth to anon, authenticated, service_role;
grant execute on function auth.uid() to anon, authenticated, service_role;

create schema if not exists test;

-- Act as one signed-in user, the way PostgREST does: switch to the authenticated role
-- and set the JWT subject. Use test.logout() to return to the superuser.
create or replace function test.login(p_user uuid) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p_user::text, false);
  execute 'set role authenticated';
end $$;

create or replace function test.logout() returns void
language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', '', false);
end $$;
