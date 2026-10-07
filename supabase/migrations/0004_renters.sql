-- 0004_renters.sql
-- Renters, drivers, identity verification, payment methods (card on file), consents.

create type identity_status as enum ('not_started', 'pending', 'verified', 'failed', 'expired');

create table renters (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid unique references users (id),
  legal_name         text not null,
  date_of_birth      date,
  address_line1      text,
  address_line2      text,
  city               text,
  province           text,
  postal_code        text,
  country            text default 'CA',
  mobile             text,
  email              text,
  identity_status    identity_status not null default 'not_started',
  is_owner_account   boolean not null default false,   -- an owner renting their own vehicle
  first_completed_booking_id uuid,                      -- FK added in 0005; drives "first rental only"
  is_blocked         boolean not null default false,
  blocked_reason     text,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
create trigger renters_updated before update on renters for each row execute function app.set_updated_at();

-- A person who may drive: the renter and each Additional Driver.
create table drivers (
  id               uuid primary key default gen_random_uuid(),
  renter_id        uuid not null references renters (id) on delete cascade, -- the account that named this driver
  is_account_holder boolean not null default false,
  user_id          uuid references users (id),
  full_name        text not null,
  date_of_birth    date not null,
  licence_number   text,
  licence_class    text,                      -- G2, G, or an accepted equivalent
  licence_issuer   text,                      -- province or country
  licence_expiry   date,
  mobile           text,
  email            text,
  identity_status  identity_status not null default 'not_started',
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index drivers_renter_idx on drivers (renter_id);
create unique index drivers_one_account_holder on drivers (renter_id) where is_account_holder;
create trigger drivers_updated before update on drivers for each row execute function app.set_updated_at();

-- Card on file. Only display details are stored here; processor tokens are admin-only.
create table payment_methods (
  id               uuid primary key default gen_random_uuid(),
  renter_id        uuid not null references renters (id) on delete cascade,
  card_brand       text,
  card_last4       text check (card_last4 ~ '^[0-9]{4}$'),
  cardholder_name  text,
  exp_month        smallint check (exp_month between 1 and 12),
  exp_year         smallint,
  is_credit        boolean,                   -- the Card on File must be a credit card in the renter's name
  status           text not null default 'active' check (status in ('active', 'expired', 'removed')),
  created_at       timestamptz not null default now()
);
create index payment_methods_renter_idx on payment_methods (renter_id);

create table payment_method_secrets (
  payment_method_id     uuid primary key references payment_methods (id) on delete cascade,
  processor             text not null default 'stripe',
  processor_customer_id text,
  processor_method_id   text,
  fingerprint           text,
  billing_address       jsonb,
  raw                   jsonb
);

-- Identity checks. Image paths and face data are purged 90 days after the rental ends,
-- or 90 days after the check if the person never rents.
create table identity_verifications (
  id                uuid primary key default gen_random_uuid(),
  driver_id         uuid not null references drivers (id) on delete cascade,
  booking_id        uuid,                      -- FK added in 0005
  method            text not null check (method in ('identity_check_service', 'staff_review')),
  status            identity_status not null default 'pending',
  provider          text,
  provider_session  text,
  id_front_document_id uuid references documents (id),
  id_back_document_id  uuid references documents (id),
  face_document_id     uuid references documents (id),
  face_match_score  numeric(5, 4),
  checks            jsonb,                     -- name, DOB, class, expiry after return date, face matches
  failure_reason    text,
  verified_by       uuid references users (id),
  verified_at       timestamptz,
  purge_after       timestamptz,
  purged_at         timestamptz,
  created_at        timestamptz not null default now(),
  check (status <> 'verified' or verified_at is not null),
  check (method <> 'staff_review' or status <> 'verified' or verified_by is not null)
);
create index identity_verifications_driver_idx on identity_verifications (driver_id);
create index identity_verifications_purge_idx on identity_verifications (purge_after) where purged_at is null;

-- Consent records (Rental Agreement Part 6; website Part 4; marketing opt-in).
create table consents (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid references users (id),
  driver_id     uuid references drivers (id),
  booking_id    uuid,                          -- FK added in 0005
  consent_code  text not null check (consent_code in (
                  'tracking_disabling', 'identity_verification', 'electronic_signature', 'card_authorization',
                  'marketing', 'owner_tracking', 'analytics_cookies')),
  text_version  text not null,                 -- version of the exact wording shown
  text_shown    text not null,                 -- snapshot of the wording, word for word
  given_at      timestamptz not null default now(),
  ip_address    inet,
  user_agent    text,
  withdrawn_at  timestamptz,
  check (user_id is not null or driver_id is not null)
);
create index consents_user_idx on consents (user_id);
create index consents_driver_idx on consents (driver_id);
create index consents_booking_idx on consents (booking_id);

alter table documents add column renter_id uuid references renters (id);
create index documents_renter_idx on documents (renter_id);
