-- 0001_foundation.sql
-- Extensions, helper schema, users and roles, program settings, documents,
-- e-signature records, audit log, job runs.
-- Conventions for the whole schema:
--   * money is bigint integer cents (CAD); percentages are integer basis points (bps)
--   * every timestamp is timestamptz; business dates are date in America/Toronto
--   * statuses are enums or check constraints
--   * standard PostgreSQL only. The single Supabase seam is app.uid() -> auth.uid().

create extension if not exists btree_gist;

create schema if not exists app;

-- ---------------------------------------------------------------- helpers
create or replace function app.uid() returns uuid
language sql stable as $$ select auth.uid() $$;
comment on function app.uid() is
  'The one place the schema touches the auth provider. Replace the body when moving off Supabase.';

create or replace function app.set_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

create or replace function app.forbid_change() returns trigger
language plpgsql as $$
begin
  raise exception '% on % is not allowed: table is append-only', tg_op, tg_table_name
    using errcode = '42501';
end $$;

-- Round to the cent, half up (half away from zero so refunds mirror charges).
create or replace function public.calc_round(n numeric) returns bigint
language sql immutable as $$ select round(n)::bigint $$;

create or replace function public.calc_bps(amount_cents bigint, bps integer) returns bigint
language sql immutable as $$ select round(amount_cents::numeric * bps / 10000)::bigint $$;

-- ---------------------------------------------------------------- time: UTC storage, Toronto rules
-- Every timestamp is stored in UTC (timestamptz). Business dates (the 1st, 10th, 15th, 18th,
-- "the month a rental ends") are calendar dates in America/Toronto, never the UTC date.
create or replace function app.tz() returns text language sql immutable as $$ select 'America/Toronto'::text $$;

create or replace function app.local_date(p_at timestamptz) returns date
language sql immutable as $$ select (p_at at time zone 'America/Toronto')::date $$;

create or replace function app.today() returns date
language sql stable as $$ select (now() at time zone 'America/Toronto')::date $$;

create or replace function app.month_start(p_on date) returns date
language sql immutable as $$ select date_trunc('month', p_on)::date $$;

create or replace function app.days_in_month(p_on date) returns integer
language sql immutable as $$ select extract(day from (date_trunc('month', p_on) + interval '1 month - 1 day'))::integer $$;

-- Midnight at the start of a Toronto calendar date, as an instant.
create or replace function app.local_midnight(p_on date) returns timestamptz
language sql immutable as $$ select (p_on::timestamp at time zone 'America/Toronto') $$;

-- Statutory holidays observed in Ontario; kept by an admin. "Business days" in the agreements
-- are Monday to Friday except the dates listed here.
create table holidays (
  holiday_on date primary key,
  name       text not null
);

create or replace function app.is_business_day(p_on date) returns boolean
language sql stable as $$
  select extract(isodow from p_on) < 6 and not exists (select 1 from holidays h where h.holiday_on = p_on)
$$;

-- The date n business days after p_from (p_from itself is day 0).
create or replace function app.add_business_days(p_from date, p_n integer) returns date
language plpgsql stable as $$
declare
  d date := p_from;
  left_ integer := p_n;
begin
  while left_ > 0 loop
    d := d + 1;
    if app.is_business_day(d) then left_ := left_ - 1; end if;
  end loop;
  return d;
end $$;

-- ---------------------------------------------------------------- users and roles
create type app_role as enum ('admin', 'va', 'field', 'owner', 'renter');
create type va_function as enum ('finance', 'fleet', 'cs', 'sales');  -- sales is the optional fourth role
create type field_function as enum ('driver', 'detailer', 'driver_detailer');

create table users (
  id                        uuid primary key default gen_random_uuid(),
  email                     text not null,
  phone                     text,
  full_name                 text not null,
  status                    text not null default 'active'
                            check (status in ('invited', 'active', 'suspended', 'closed')),
  marketing_opt_in          boolean not null default false,
  marketing_opt_in_at       timestamptz,
  marketing_unsubscribed_at timestamptz,
  last_sign_in_at           timestamptz,
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now()
);
comment on table users is 'One row per login. id equals auth.users.id on Supabase (no FK, to stay host-portable).';
create unique index users_email_key on users (lower(email));
create trigger users_updated before update on users for each row execute function app.set_updated_at();

create table user_roles (
  user_id    uuid not null references users (id) on delete cascade,
  role       app_role not null,
  granted_by uuid references users (id),
  granted_at timestamptz not null default now(),
  primary key (user_id, role)
);
comment on table user_roles is 'A user may hold several roles (an owner who also rents; field staff who refer renters).';
create index user_roles_role_idx on user_roles (role);

create table staff_profiles (
  user_id               uuid primary key references users (id) on delete cascade,
  staff_type            text not null check (staff_type in ('va', 'field')),
  va_function           va_function,
  field_function        field_function,
  referral_code         text unique,
  agreement_document_id uuid,
  started_on            date,
  ended_on              date,
  is_active             boolean not null default true,
  -- VA Agreement Schedule A (finance role). Both start at $0: an admin releases every payment.
  single_limit_cents            bigint not null default 0 check (single_limit_cents >= 0),
  dual_approval_threshold_cents bigint not null default 0 check (dual_approval_threshold_cents >= 0),
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  check ((staff_type = 'va') = (va_function is not null)),
  check ((staff_type = 'field') = (field_function is not null)),
  -- virtual assistants never earn a referral kickback, so they hold no referral code
  check (staff_type = 'field' or referral_code is null)
);
create trigger staff_profiles_updated before update on staff_profiles for each row execute function app.set_updated_at();

-- ---------------------------------------------------------------- program settings
-- Enrollment Agreement Schedule B Part 1 "standard numbers" plus platform-wide numbers.
-- Versioned: the row with the latest effective_from <= today applies.
create table program_settings (
  id                          uuid primary key default gen_random_uuid(),
  effective_from              date not null unique,
  timezone                    text not null default 'America/Toronto',
  hst_bps                     integer not null default 1300 check (hst_bps between 0 and 10000),
  billing_day                 smallint not null default 15 check (billing_day between 1 and 28),
  retry_day                   smallint not null default 18 check (retry_day between 1 and 28),
  payout_day                  smallint not null default 10 check (payout_day between 1 and 28),
  fleet_report_day            smallint not null default 1 check (fleet_report_day between 1 and 28),
  investor_payment_day        smallint not null default 15 check (investor_payment_day between 1 and 28),
  owner_late_fee_cents        bigint not null default 5000 check (owner_late_fee_cents >= 0),
  install_fee_cents           bigint not null default 10000 check (install_fee_cents >= 0),
  deductible_cents            bigint not null default 250000 check (deductible_cents >= 0),
  kickback_bps                integer not null default 2000 check (kickback_bps between 0 and 10000),
  shareholder_company_share_bps integer not null default 1000 check (shareholder_company_share_bps between 0 and 10000),
  non_refundable_discount_bps integer not null default 1000 check (non_refundable_discount_bps between 0 and 10000),
  notice_period_days          integer not null default 30,
  free_retransfer_months      integer not null default 6,
  buyout_premium_bps          integer not null default 1000,
  max_rental_days             integer not null default 30,
  min_renter_age              integer not null default 18,
  standard_min_age            integer not null default 21,
  safety_certificate_days     integer not null default 36,
  liability_floor_cents       bigint not null default 500000,
  min_fleet_count             integer not null default 10,
  tentative_hold_minutes      integer not null default 120,
  turnaround_buffer_minutes   integer not null default 0,
  deposit_hold_max_days       integer not null default 7,
  deposit_release_business_days integer not null default 7,
  deposit_holdback_days       integer not null default 30,
  refund_business_days        integer not null default 10,
  investor_min_cents          bigint not null default 2000000,
  investor_lockup_months      integer not null default 6,
  investor_redemption_notice_months integer not null default 6,
  retention_id_face_days      integer not null default 90,
  retention_tracker_months    integer not null default 12,
  retention_records_years     integer not null default 7,
  owner_arrears_removal_days  integer not null default 30,   -- unpaid 30 days after the failed retry
  retransfer_business_days    integer not null default 10,
  total_loss_balance_business_days integer not null default 10,
  damage_late_report_hours    integer not null default 48,
  fleet_warning_count         integer not null default 11,   -- warn an admin at 11 or fewer
  staff_customer_window_days  integer not null default 90,   -- how long after a rental ends staff may still open the renter's record
  company_legal_name          text not null default '18122211 Canada Inc.',
  company_trade_name          text not null default 'CarmaCars',
  company_hst_number          text,                          -- printed on invoices once registered
  company_address             text,
  company_email               text,
  company_phone               text,
  incident_line_phone         text,
  privacy_officer_name        text,
  privacy_officer_email       text,
  created_by                  uuid references users (id),
  created_at                  timestamptz not null default now()
);

create or replace function app.settings(p_on date default (now() at time zone 'America/Toronto')::date)
returns program_settings language sql stable security definer set search_path = public, app as $$
  select * from program_settings where effective_from <= p_on order by effective_from desc limit 1
$$;

-- ---------------------------------------------------------------- documents and signatures
create type document_kind as enum (
  'rental_agreement', 'condition_report', 'renter_statement', 'coverage_proof', 'coverage_terms',
  'coverage_activation', 'id_front', 'id_back', 'face_photo',
  'enrollment_agreement', 'title_agreement', 'vehicle_schedule', 'additional_vehicle_schedule',
  'title_schedule', 'form_a_trust_declaration', 'form_b_lease_summary', 'form_c_finance_permission_ack',
  'form_d_power_of_attorney', 'form_e_exit_checklist', 'finance_party_permission',
  'ownership_permit', 'insurer_confirmation', 'owner_insurance_proof', 'safety_certificate', 'appraisal',
  'registry_form', 'owner_invoice', 'owner_statement', 'receipt',
  'repair_estimate', 'repair_invoice', 'police_report', 'incident_report', 'toll_ticket_notice',
  'investment_agreement', 'investment_schedule_a', 'investment_schedule_c', 'investment_schedule_d',
  'investor_statement', 'securities_form', 'fleet_report', 'staff_agreement', 'notice', 'dispute_evidence',
  'other'
);

create type retention_class as enum ('id_face_90d', 'tracker_12m', 'records_7y', 'until_unsubscribe', 'permanent');

create table documents (
  id               uuid primary key default gen_random_uuid(),
  kind             document_kind not null,
  title            text,
  storage_bucket   text not null,
  storage_path     text,                       -- null once purged
  mime_type        text,
  sha256           text,
  template_version text,                       -- which agreement template produced it
  retention        retention_class not null default 'records_7y',
  purge_after      timestamptz,                -- set when the retention clock starts
  legal_hold       boolean not null default false, -- claim, dispute, unpaid amount or legal duty
  purged_at        timestamptz,
  uploaded_by      uuid references users (id),
  created_at       timestamptz not null default now(),
  check (storage_path is not null or purged_at is not null)
);
comment on table documents is 'Metadata for every stored file. Files live in object storage; entity links (booking_id, owner_id, ...) are added by later migrations.';
create index documents_purge_idx on documents (purge_after) where purged_at is null and not legal_hold;

alter table staff_profiles
  add constraint staff_profiles_agreement_fk foreign key (agreement_document_id) references documents (id);

create table signature_requests (
  id                 uuid primary key default gen_random_uuid(),
  document_id        uuid not null references documents (id),
  provider           text not null,            -- electronic signature service (adapter name)
  provider_envelope  text,                     -- provider reference
  status             text not null default 'draft'
                     check (status in ('draft', 'sent', 'partially_signed', 'completed', 'declined', 'voided', 'expired')),
  sent_at            timestamptz,
  completed_at       timestamptz,
  signed_document_id uuid references documents (id),
  created_by         uuid references users (id),
  created_at         timestamptz not null default now(),
  unique (provider, provider_envelope)
);
create index signature_requests_document_idx on signature_requests (document_id);

create table signature_records (
  id                   uuid primary key default gen_random_uuid(),
  signature_request_id uuid not null references signature_requests (id) on delete cascade,
  signer_role          text not null check (signer_role in (
                         'renter', 'additional_driver', 'carmacars', 'owner_individual', 'owner_corporation',
                         'lessor', 'investor', 'witness', 'staff')),
  signer_user_id       uuid references users (id),
  signer_name          text not null,
  signer_title         text,
  signer_email         text,
  status               text not null default 'pending' check (status in ('pending', 'signed', 'declined')),
  signed_at            timestamptz,
  method               text,                    -- method of acceptance recorded by the service
  ip_address           inet,
  user_agent           text,
  provider_signature   text,                    -- provider's signature/evidence reference
  initials             jsonb,                   -- e.g. {"3.3": "AB", "2.3_4.3": "AB"} for initialled confirmations
  created_at           timestamptz not null default now(),
  check (status <> 'signed' or signed_at is not null)
);
create index signature_records_request_idx on signature_records (signature_request_id);
create index signature_records_user_idx on signature_records (signer_user_id);

-- ---------------------------------------------------------------- audit log
create table audit_log (
  id            bigint generated always as identity primary key,
  at            timestamptz not null default now(),
  actor_user_id uuid,
  actor_db_role text not null default current_user,
  action        text not null,                 -- INSERT / UPDATE / DELETE or an application verb
  entity_table  text not null,
  entity_id     text,
  before        jsonb,
  after         jsonb,
  ip_address    inet,
  request_id    text
);
create index audit_log_entity_idx on audit_log (entity_table, entity_id, at desc);
create index audit_log_actor_idx on audit_log (actor_user_id, at desc);
create trigger audit_log_append_only before update or delete on audit_log
  for each row execute function app.forbid_change();

create or replace function app.audit_row() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_id text;
  v_row jsonb;
begin
  if tg_op = 'DELETE' then v_row := to_jsonb(old); else v_row := to_jsonb(new); end if;
  -- most tables key on id; a few key on the parent (booking_id, payment_id, ...)
  v_id := coalesce(v_row ->> 'id', v_row ->> 'booking_id', v_row ->> 'payment_id', v_row ->> 'code',
                   v_row ->> 'user_id', v_row ->> 'vehicle_id');
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (app.uid(), tg_op, tg_table_name, v_id,
          -- tables holding processor tokens or bank numbers pass 'redact': the change is logged, the values are not
          case when tg_op in ('UPDATE', 'DELETE') and coalesce(tg_argv[0], '') <> 'redact' then to_jsonb(old) end,
          case when tg_op in ('INSERT', 'UPDATE') and coalesce(tg_argv[0], '') <> 'redact' then to_jsonb(new) end);
  return coalesce(new, old);
end $$;

create trigger audit_user_roles after insert or update or delete on user_roles
  for each row execute function app.audit_row();
create trigger audit_program_settings after insert or update or delete on program_settings
  for each row execute function app.audit_row();

-- ---------------------------------------------------------------- background job runs
create table job_runs (
  id          uuid primary key default gen_random_uuid(),
  job_name    text not null,
  run_key     text not null,                   -- e.g. 'owner-billing:2026-11' makes each run idempotent
  status      text not null default 'running' check (status in ('running', 'succeeded', 'failed')),
  started_at  timestamptz not null default now(),
  finished_at timestamptz,
  summary     jsonb,
  error       text,
  unique (job_name, run_key)
);
