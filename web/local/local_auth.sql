-- LOCAL ONLY. Never applied to Supabase. A stand-in for Supabase Auth (GoTrue) on the local
-- database, used by src/lib/auth/local.ts: email and password accounts, password reset tokens
-- and a mailbox that holds the emails Supabase would have sent. Passwords are scrypt hashes
-- made by the app; nothing here is readable by the API roles.
create schema if not exists local_auth;
revoke all on schema local_auth from public;

create table if not exists local_auth.users (
  id            uuid primary key,
  email         text not null unique,
  password_hash text not null,
  created_at    timestamptz not null default now(),
  last_sign_in_at timestamptz
);

create table if not exists local_auth.reset_tokens (
  token_hash text primary key,
  user_id    uuid not null references local_auth.users (id) on delete cascade,
  expires_at timestamptz not null,
  used_at    timestamptz
);

create table if not exists local_auth.mailbox (
  id         bigserial primary key,
  to_email   text not null,
  subject    text not null,
  body       text not null,
  link       text,
  created_at timestamptz not null default now()
);

-- Two-step sign-in: TOTP factors (Supabase Auth keeps these in auth.mfa_factors).
create table if not exists local_auth.factors (
  id          uuid primary key,
  user_id     uuid not null references local_auth.users (id) on delete cascade,
  secret      text not null,
  verified_at timestamptz,
  created_at  timestamptz not null default now()
);
