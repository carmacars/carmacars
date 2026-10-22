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

-- Sign-up confirmation, as Supabase Auth does it (0045): an account made through the sign-up form waits for the link
-- emailed to it (local_auth.mailbox) before it can sign in. Rows inserted directly (tests, seeds) are confirmed.
alter table local_auth.users add column if not exists email_confirmed_at timestamptz default now();
alter table local_auth.reset_tokens add column if not exists kind text not null default 'recovery';

-- Two-step sign-in: TOTP factors (Supabase Auth keeps these in auth.mfa_factors).
create table if not exists local_auth.factors (
  id          uuid primary key,
  user_id     uuid not null references local_auth.users (id) on delete cascade,
  secret      text not null,
  verified_at timestamptz,
  created_at  timestamptz not null default now()
);

-- Phone sign-in (0091), as Supabase Auth's phone provider does it: an account may have a phone instead of an email;
-- codes (6 digits, 5 minutes) are kept as hashes and "texted" through the site's SMS sender (the fake Quo line) and
-- written to the mailbox (to_phone) so the tests read them like the emails.
alter table local_auth.users alter column email drop not null;
alter table local_auth.users add column if not exists phone text unique;
alter table local_auth.users add column if not exists phone_confirmed_at timestamptz;
alter table local_auth.mailbox alter column to_email drop not null;
alter table local_auth.mailbox add column if not exists to_phone text;
create table if not exists local_auth.otps (
  id         bigserial primary key,
  phone      text not null,
  user_id    uuid references local_auth.users (id) on delete cascade,
  kind       text not null check (kind in ('sms', 'phone_change')),
  code_hash  text not null,
  attempts   integer not null default 0,
  expires_at timestamptz not null,
  used_at    timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists otps_phone_idx on local_auth.otps (phone, created_at desc);
