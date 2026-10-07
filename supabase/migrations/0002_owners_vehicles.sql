-- 0002_owners_vehicles.sql
-- Owners, owner agreements and forms, vehicles, signed vehicle schedules, fee history,
-- onboarding, registration, exit, buyout, Turo, calendar, listings and the photo pipeline.

create type owner_type as enum ('individual', 'corporation');
create type management_mode as enum ('managed', 'self_managed', 'turo_only');
create type onboarding_method as enum (
  'lease_existing_corporation', 'lease_new_owner_corporation', 'co_registrant', 'transfer', 'none');
create type title_status as enum ('owned_outright', 'financed', 'leased');
create type finance_permission as enum ('not_applicable', 'attached', 'not_obtained');
create type owners_lien as enum ('not_available', 'elected', 'declined');
create type vehicle_class as enum ('economy', 'standard', 'premium', 'suv', 'luxury', 'exotic');
create type fuel_type as enum ('gasoline', 'diesel', 'hybrid', 'plug_in_hybrid', 'electric');

create type vehicle_status as enum (
  'onboarding', 'ready_to_list', 'available', 'on_rent', 'cleaning', 'out_of_service',
  'exit_notice', 'exited', 'total_loss', 'declined');

create type vehicle_onboarding_status as enum (
  'intake', 'declined', 'terms_set', 'documents_sent', 'documents_signed', 'upfront_paid',
  'registry_booked', 'registered', 'tracker_installed', 'on_fleet_policy', 'enrolled', 'withdrawn');

-- ---------------------------------------------------------------- owners
create table owners (
  id                      uuid primary key default gen_random_uuid(),
  user_id                 uuid references users (id),
  owner_type              owner_type not null,
  legal_name              text not null,
  corporation_name        text,
  corporation_number      text,
  registrant_identification_number text,       -- RIN, Form B lessor
  is_new_owner_corporation boolean not null default false,
  address_line1           text,
  address_line2           text,
  city                    text,
  province                text default 'ON',
  postal_code             text,
  country                 text default 'CA',
  email                   text,
  phone                   text,
  hst_number              text,                 -- HST is added to payouts only when on file
  referral_code           text unique,          -- quoted by a renter the owner refers
  is_shareholder          boolean not null default false, -- a Principal (or the Principal's holding corporation)
  payout_method           text not null default 'bank_transfer' check (payout_method in ('bank_transfer', 'e_transfer')),
  balance_carried_forward_cents bigint not null default 0, -- negative = debt payable on demand
  status                  text not null default 'lead'
                          check (status in ('lead', 'active', 'in_default', 'exited')),
  recruited_by            uuid references users (id),
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now()
);
create index owners_user_idx on owners (user_id);
create trigger owners_updated before update on owners for each row execute function app.set_updated_at();

-- Banking details: visible to admins and the owner only (never to VAs or field staff).
create table owner_payout_accounts (
  id               uuid primary key default gen_random_uuid(),
  owner_id         uuid not null references owners (id) on delete cascade,
  method           text not null check (method in ('bank_transfer', 'e_transfer')),
  account_holder   text not null,
  institution_no   text,
  transit_no       text,
  account_no       text,            -- application-layer encrypted
  account_last4    text,
  e_transfer_email text,
  is_current       boolean not null default true,
  verified_at      timestamptz,
  created_at       timestamptz not null default now()
);
create unique index owner_payout_accounts_current on owner_payout_accounts (owner_id) where is_current;

-- Pre-authorized debit authorization and card on file used to pay Fees.
create table owner_payment_methods (
  id                  uuid primary key default gen_random_uuid(),
  owner_id            uuid not null references owners (id) on delete cascade,
  kind                text not null check (kind in ('pre_authorized_debit', 'card')),
  status              text not null default 'active' check (status in ('pending', 'active', 'revoked', 'failed')),
  brand_or_bank       text,
  last4               text,
  authorization_document_id uuid references documents (id),
  authorized_at       timestamptz,
  is_default          boolean not null default false,
  created_at          timestamptz not null default now()
);
create index owner_payment_methods_owner_idx on owner_payment_methods (owner_id);

-- Processor tokens for owner payment methods: admin only.
create table owner_payment_method_secrets (
  owner_payment_method_id uuid primary key references owner_payment_methods (id) on delete cascade,
  processor               text not null default 'stripe',
  processor_customer_id   text,
  processor_method_id     text,
  processor_mandate_id    text,
  raw                     jsonb
);

-- ---------------------------------------------------------------- owner agreements
-- One Enrollment Agreement per owner covers all of that owner's vehicles.
-- The Title-Holding and Lease Agreement is a second agreement (not used for Turo-Only).
create table owner_agreements (
  id                  uuid primary key default gen_random_uuid(),
  owner_id            uuid not null references owners (id),
  kind                text not null check (kind in ('enrollment', 'title_holding')),
  agreement_number    text not null unique,
  agreement_date      date,
  status              text not null default 'draft'
                      check (status in ('draft', 'sent', 'signed', 'ended', 'void')),
  document_id         uuid references documents (id),
  signature_request_id uuid references signature_requests (id),
  -- Enrollment Agreement initialled confirmations (3.3; 2.3 and 4.3; 5, 10 and 15)
  confirm_own_insurance_at    timestamptz,
  confirm_fees_no_income_at   timestamptz,
  confirm_tracker_downtime_at timestamptz,
  corporate_signatory_name    text,
  corporate_signatory_title   text,
  ended_at            timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create unique index owner_agreements_one_live on owner_agreements (owner_id, kind)
  where status in ('draft', 'sent', 'signed');
create trigger owner_agreements_updated before update on owner_agreements for each row execute function app.set_updated_at();

-- ---------------------------------------------------------------- vehicles
create table vehicles (
  id                 uuid primary key default gen_random_uuid(),
  owner_id           uuid not null references owners (id),
  fleet_number       text unique,                -- internal fleet register number
  year               smallint not null check (year between 1980 and 2100),
  make               text not null,
  model              text not null,
  trim               text,
  colour             text,
  fuel               fuel_type not null default 'gasoline',
  vin                text not null check (length(vin) = 17),
  plate              text,
  odometer_km        integer check (odometer_km >= 0),
  class              vehicle_class not null default 'standard',
  status             vehicle_status not null default 'onboarding',
  management_mode    management_mode not null default 'managed',
  onboarding_method  onboarding_method,
  is_shareholder_owned boolean not null default false, -- 90/10, no Fees, no upfront charges
  allows_18_to_20    boolean not null default false,   -- only flagged cars may go to drivers under 21
  bookings_enabled   boolean not null default true,    -- false: Self-Managed car in arrears
  in_arrears         boolean not null default false,
  on_fleet_policy    boolean not null default false,
  fleet_policy_added_on   date,
  fleet_policy_removed_on date,
  enrollment_date    date,                        -- date of written confirmation (T22) or live on Turo
  exit_date          date,
  title_brand_clear  boolean,                     -- false = rebuilt/salvage/irreparable: not eligible
  total_loss_decided_on date,                     -- the Insurer's decision: Fees stop on this date
  home_location      text,
  -- The four cases of the owner billing spec (section 3). "Shareholder" is a Managed vehicle owned
  -- by a Principal, so it is a flag plus this derived column rather than a fourth management mode.
  billing_case       text generated always as (
                       case when is_shareholder_owned then 'shareholder'
                            when management_mode = 'managed' then 'managed'
                            when management_mode = 'self_managed' then 'self_managed'
                            else 'turo_only' end) stored,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  check (exit_date is null or enrollment_date is null or exit_date >= enrollment_date),
  check (management_mode <> 'turo_only' or not on_fleet_policy),
  check (management_mode <> 'turo_only' or not is_shareholder_owned),
  check (not is_shareholder_owned or management_mode = 'managed')
);
create unique index vehicles_vin_key on vehicles (upper(vin));
create index vehicles_owner_idx on vehicles (owner_id);
create index vehicles_status_idx on vehicles (status);
create index vehicles_plate_idx on vehicles (upper(plate));
create trigger vehicles_updated before update on vehicles for each row execute function app.set_updated_at();

-- ---------------------------------------------------------------- signed vehicle schedules
-- One row per signed Schedule A entry (and its Title Schedule entry). A Revenue Share,
-- mode or method change is a new signed row that supersedes the previous one.
create table vehicle_schedules (
  id                  uuid primary key default gen_random_uuid(),
  vehicle_id          uuid not null references vehicles (id),
  owner_agreement_id  uuid not null references owner_agreements (id),
  title_agreement_id  uuid references owner_agreements (id),
  schedule_number     text not null unique,
  vehicle_number      integer not null check (vehicle_number > 0), -- "Vehicle no." within the owner's schedule
  is_additional       boolean not null default false,  -- added by an Additional Vehicle Schedule
  odometer_km         integer check (odometer_km >= 0),
  held_by             owner_type not null,
  title_status        title_status not null,
  finance_party_name  text,
  finance_party_account text,
  finance_permission  finance_permission not null default 'not_applicable',
  finance_permission_document_id uuid references documents (id),
  management_mode     management_mode not null,
  onboarding_method   onboarding_method not null,
  insurance_fee_cents bigint not null check (insurance_fee_cents >= 0),
  tracker_fee_cents   bigint not null check (tracker_fee_cents >= 0),
  install_fee_cents   bigint not null default 10000 check (install_fee_cents >= 0),
  revenue_share_bps   integer not null check (revenue_share_bps between 0 and 10000),
  enrollment_date     date,
  special_terms       text,
  owners_lien         owners_lien not null default 'not_available',
  ppsa_registration_number text,
  onboarding_estimate_cents bigint,               -- information only; the owner pays third parties directly
  document_id         uuid references documents (id),
  signature_request_id uuid references signature_requests (id),
  signed_at           timestamptz,
  superseded_by       uuid references vehicle_schedules (id),
  superseded_at       timestamptz,
  created_by          uuid references users (id),
  created_at          timestamptz not null default now(),
  check ((title_status = 'owned_outright') = (finance_party_name is null)),
  check (title_status = 'owned_outright' or finance_permission <> 'not_applicable'),
  check ((management_mode = 'turo_only') = (onboarding_method = 'none')),
  -- a Leased vehicle can only use the Transfer method (or none when Turo-Only)
  check (title_status <> 'leased' or onboarding_method in ('transfer', 'none')),
  check (onboarding_method <> 'lease_existing_corporation' or held_by = 'corporation'),
  check (onboarding_method not in ('lease_new_owner_corporation', 'co_registrant') or held_by = 'individual'),
  -- the Owner's Lien exists only on an Owned Outright vehicle under the Transfer method
  check (owners_lien = 'not_available' or (title_status = 'owned_outright' and onboarding_method = 'transfer')),
  -- Self-Managed: the owner is paid 100% of Owner Revenue
  check (management_mode <> 'self_managed' or revenue_share_bps = 0),
  -- Turo-Only: no Fees and no tracker
  check (management_mode <> 'turo_only' or (insurance_fee_cents = 0 and tracker_fee_cents = 0 and install_fee_cents = 0))
);
create unique index vehicle_schedules_current on vehicle_schedules (vehicle_id) where superseded_by is null;
create unique index vehicle_schedules_number_in_agreement on vehicle_schedules (owner_agreement_id, vehicle_number)
  where superseded_by is null;
create index vehicle_schedules_agreement_idx on vehicle_schedules (owner_agreement_id);
create trigger audit_vehicle_schedules after insert or update or delete on vehicle_schedules
  for each row execute function app.audit_row();

-- Effective fee terms over time. A new signed schedule or a 30-day fee notice closes the
-- previous row and opens a new one; rows never overlap.
create table vehicle_fee_history (
  id                  uuid primary key default gen_random_uuid(),
  vehicle_id          uuid not null references vehicles (id),
  vehicle_schedule_id uuid references vehicle_schedules (id),
  source              text not null check (source in ('signed_schedule', 'fee_notice', 'shareholder', 'correction')),
  insurance_fee_cents bigint not null check (insurance_fee_cents >= 0),
  tracker_fee_cents   bigint not null check (tracker_fee_cents >= 0),
  revenue_share_bps   integer not null check (revenue_share_bps between 0 and 10000),
  effective_from      date not null,
  effective_to        date,                       -- exclusive; null = current
  notice_sent_on      date,                       -- fee changes need 30 days' written notice
  notice_document_id  uuid references documents (id),
  created_by          uuid references users (id),
  created_at          timestamptz not null default now(),
  check (effective_to is null or effective_to > effective_from),
  -- a Fee change by notice may not take effect sooner than 30 days after the notice
  check (source <> 'fee_notice' or (notice_sent_on is not null and effective_from >= notice_sent_on + 30)),
  exclude using gist (vehicle_id with =, daterange(effective_from, effective_to, '[)') with &&)
);

-- A Revenue Share changes only by a new signed schedule, never by a fee notice.
create or replace function app.fee_notice_keeps_share() returns trigger
language plpgsql as $$
declare
  v_prev integer;
begin
  if new.source = 'fee_notice' then
    select revenue_share_bps into v_prev from vehicle_fee_history
     where vehicle_id = new.vehicle_id and effective_from < new.effective_from
     order by effective_from desc limit 1;
    if v_prev is not null and v_prev <> new.revenue_share_bps then
      raise exception 'A Revenue Share changes only by a new signed Vehicle Schedule' using errcode = '23514';
    end if;
  end if;
  return new;
end $$;
create trigger vehicle_fee_history_share_guard before insert on vehicle_fee_history
  for each row execute function app.fee_notice_keeps_share();
create index vehicle_fee_history_vehicle_idx on vehicle_fee_history (vehicle_id, effective_from desc);
create trigger audit_vehicle_fee_history after insert or update or delete on vehicle_fee_history
  for each row execute function app.audit_row();

create or replace function app.vehicle_terms(p_vehicle uuid, p_on date)
returns vehicle_fee_history language sql stable as $$
  select * from vehicle_fee_history
  where vehicle_id = p_vehicle and effective_from <= p_on and (effective_to is null or effective_to > p_on)
  limit 1
$$;

-- Forms A to E of the Title Agreement (C and E are per vehicle; A, B and D cover all).
create table owner_agreement_forms (
  id                 uuid primary key default gen_random_uuid(),
  owner_agreement_id uuid not null references owner_agreements (id),
  form_code          text not null check (form_code in ('A', 'B', 'C', 'D1', 'D2', 'E')),
  vehicle_id         uuid references vehicles (id),
  document_id        uuid references documents (id),
  signature_request_id uuid references signature_requests (id),
  signed_at          timestamptz,
  witness_1_name     text,
  witness_2_name     text,
  finance_permission finance_permission,                -- Form C
  ack_read_warning_at       timestamptz,                -- Form C initials
  ack_no_advice_at          timestamptz,
  ack_bears_consequences_at timestamptz,
  created_at         timestamptz not null default now(),
  check (form_code <> 'E' or vehicle_id is not null)
);
create index owner_agreement_forms_agreement_idx on owner_agreement_forms (owner_agreement_id);
create index owner_agreement_forms_vehicle_idx on owner_agreement_forms (vehicle_id);

-- ---------------------------------------------------------------- reference: onboarding methods and fee grid
create table onboarding_method_info (
  method             onboarding_method primary key,
  label              text not null,
  open_to            text not null,
  typical_items      jsonb not null default '[]',
  estimate_cents     bigint not null,
  estimate_with_lien_cents bigint,
  plus_tax           boolean not null default false,
  government_forms   text[] not null default '{}',
  updated_at         timestamptz not null default now()
);
comment on table onboarding_method_info is 'Information only. CarmaCars never bills these; the owner pays third parties directly.';

create table owner_fee_grid (
  id                  uuid primary key default gen_random_uuid(),
  min_vehicles        integer not null,
  max_vehicles        integer,
  insurance_fee_cents bigint not null,
  revenue_share_bps   integer not null,
  tracker_fee_cents   bigint not null,
  effective_from      date not null default current_date,
  unique (min_vehicles, effective_from)
);
comment on table owner_fee_grid is 'Starting point only. Amounts always come from the signed vehicle schedule.';

-- ---------------------------------------------------------------- per-vehicle onboarding
create table vehicle_onboardings (
  id                    uuid primary key default gen_random_uuid(),
  vehicle_id            uuid not null unique references vehicles (id),
  status                vehicle_onboarding_status not null default 'intake',
  current_insurer       text,                      -- intake (T20)
  decline_reason        text,
  broker_preapproved_at timestamptz,
  terms_set_by          uuid references users (id),
  terms_set_at          timestamptz,
  documents_sent_at     timestamptz,
  documents_signed_at   timestamptz,
  upfront_invoice_id    uuid,                      -- FK added in 0007
  upfront_paid_at       timestamptz,
  safety_certificate_on date,
  safety_certificate_expires_on date,
  appraisal_on          date,
  registry_visit_at     timestamptz,
  registry_place        text,
  registry_attended_by  uuid references users (id),
  permit_filed_at       timestamptz,
  tracker_installed_at  timestamptz,
  tracker_tested_at     timestamptz,
  owner_access_granted_at timestamptz,
  on_fleet_policy_at    timestamptz,
  insurer_confirmation_document_id uuid references documents (id),
  enrolled_confirmed_at timestamptz,               -- T22 sent: this date is the Enrollment Date
  -- Turo-Only: documents instead of registry, policy and tracker
  owner_insurance_expires_on date,
  insurer_permits_turo_confirmed_at timestamptz,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);
create trigger vehicle_onboardings_updated before update on vehicle_onboardings for each row execute function app.set_updated_at();

-- Title Schedule completion: how CarmaCars appears at the Registry.
create table vehicle_registrations (
  id                 uuid primary key default gen_random_uuid(),
  vehicle_id         uuid not null references vehicles (id),
  registered_as      text not null check (registered_as in ('owner', 'plate_registrant', 'co_registrant', 'lessee')),
  registered_on      date not null,
  plate              text,
  plate_renewal_month smallint check (plate_renewal_month between 1 and 12),
  permit_document_id uuid references documents (id),
  lease_recorded_on  date,                          -- Form B start
  retransferred_on   date,
  retransferred_to   text,
  created_at         timestamptz not null default now()
);
create unique index vehicle_registrations_current on vehicle_registrations (vehicle_id) where retransferred_on is null;

-- ---------------------------------------------------------------- exit, re-transfer, buyout
create table vehicle_exits (
  id                   uuid primary key default gen_random_uuid(),
  vehicle_id           uuid not null references vehicles (id),
  initiated_by         text not null check (initiated_by in ('owner', 'carmacars', 'insurer_declined', 'owner_default', 'total_loss', 'buyout')),
  reason               text,
  notice_received_at   timestamptz not null,
  notice_ends_on       date not null,
  exit_date            date not null,              -- end of notice or, if later, of a rental in progress
  confirmed_to_owner_at timestamptz,
  status               text not null default 'notice'
                       check (status in ('notice', 'exited', 'retransferred', 'cancelled')),
  months_on_fleet_policy integer,
  retransfer_fees_paid_by text check (retransfer_fees_paid_by in ('owner', 'carmacars')),
  retransfer_fees_cents bigint,
  owner_insurance_document_id uuid references documents (id),
  tracker_removed_at   timestamptz,
  exit_odometer_km     integer,
  policy_removed_at    timestamptz,
  retransfer_due_on    date,                       -- 10 business days after the Exit Date
  retransfer_completed_at timestamptz,
  retransferred_to     text,
  owner_reminder_at    timestamptz,                -- written reminder: 5 business days, then Form D Part 2
  lien_discharged_at   timestamptz,
  form_e_document_id   uuid references documents (id),
  created_at           timestamptz not null default now(),
  check (exit_date >= notice_ends_on or initiated_by in ('insurer_declined', 'owner_default', 'total_loss', 'buyout'))
);
create unique index vehicle_exits_open on vehicle_exits (vehicle_id) where status in ('notice', 'exited');

create table vehicle_buyouts (
  id                    uuid primary key default gen_random_uuid(),
  vehicle_id            uuid not null references vehicles (id),
  offered_on            date not null,              -- the owner's written offer
  offer_document_id     uuid references documents (id),
  black_book_value_cents bigint check (black_book_value_cents >= 0), -- Canadian Black Book average trade-in
  premium_bps           integer not null default 1000,
  price_cents           bigint,                     -- value x (1 + premium)
  sales_tax_cents       bigint not null default 0,
  finance_party_payout_cents bigint not null default 0,
  status                text not null default 'offered'
                        check (status in ('offered', 'declined', 'accepted', 'closed', 'lapsed')),
  decided_by            uuid references users (id),
  closes_by             date,                       -- within 30 days
  closed_on             date,
  created_at            timestamptz not null default now()
);
create index vehicle_buyouts_vehicle_idx on vehicle_buyouts (vehicle_id);

-- ---------------------------------------------------------------- Turo-Only
create table turo_listings (
  id                  uuid primary key default gen_random_uuid(),
  vehicle_id          uuid not null unique references vehicles (id),
  turo_listing_ref    text,
  status              text not null default 'draft' check (status in ('draft', 'listed', 'paused', 'unlisted')),
  listed_at           timestamptz,
  owner_insurance_expires_on date,
  plate_expires_on    date,
  expiry_reminder_sent_at timestamptz,             -- T23, 14 days before
  created_at          timestamptz not null default now()
);

create table turo_trips (
  id                   uuid primary key default gen_random_uuid(),
  vehicle_id           uuid not null references vehicles (id),
  turo_trip_ref        text not null unique,
  starts_at            timestamptz not null,
  ends_at              timestamptz not null,
  gross_cents          bigint not null check (gross_cents >= 0), -- trip price + distance fees
  turo_fees_cents      bigint not null check (turo_fees_cents >= 0),
  net_payout_cents     bigint generated always as (gross_cents - turo_fees_cents) stored, -- the "Turo Payout"
  company_extras_cents bigint not null default 0,  -- delivery and extras: stay with CarmaCars
  damage_payment_cents bigint not null default 0,  -- passes to the owner
  revenue_share_bps    integer not null check (revenue_share_bps between 0 and 10000),
  revenue_share_cents  bigint not null,          -- share of the Turo Payout kept by CarmaCars
  owner_payout_cents   bigint generated always as
                       (gross_cents - turo_fees_cents - revenue_share_cents + damage_payment_cents) stored,
  statement_month      date,                     -- the month the trip ends (Toronto)
  received_at          timestamptz,
  created_at           timestamptz not null default now(),
  check (ends_at > starts_at),
  check (statement_month is null or extract(day from statement_month) = 1),
  check (revenue_share_cents = public.calc_bps(gross_cents - turo_fees_cents, revenue_share_bps))
);
create index turo_trips_vehicle_month_idx on turo_trips (vehicle_id, statement_month);

-- ---------------------------------------------------------------- calendar blocks
create table vehicle_calendar_blocks (
  id          uuid primary key default gen_random_uuid(),
  vehicle_id  uuid not null references vehicles (id) on delete cascade,
  reason      text not null check (reason in ('service', 'repair', 'owner_unavailable', 'cleaning', 'exit', 'turo_owner_use', 'admin')),
  starts_at   timestamptz not null,
  ends_at     timestamptz,                         -- null = open ended (e.g. after an Exit Date)
  note        text,
  created_by  uuid references users (id),
  created_at  timestamptz not null default now(),
  check (ends_at is null or ends_at > starts_at)
);
create index vehicle_calendar_blocks_idx on vehicle_calendar_blocks using gist (vehicle_id, tstzrange(starts_at, ends_at, '[)'));

-- ---------------------------------------------------------------- website listing and photo pipeline
create table vehicle_listings (
  id            uuid primary key default gen_random_uuid(),
  vehicle_id    uuid not null unique references vehicles (id) on delete cascade,
  slug          text unique,
  headline      text,
  description   text,
  features      text[] not null default '{}',
  seats         smallint,
  transmission  text,
  status        text not null default 'draft' check (status in ('draft', 'ready', 'published', 'paused', 'unpublished')),
  published_at  timestamptz,
  published_by  uuid references users (id),
  channels      text[] not null default '{}',      -- website, classified sites, social pages
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create trigger vehicle_listings_updated before update on vehicle_listings for each row execute function app.set_updated_at();

-- Interface to the AI photo pipeline. The platform enqueues a job; the pipeline writes results back.
create table photo_jobs (
  id            uuid primary key default gen_random_uuid(),
  vehicle_id    uuid not null references vehicles (id) on delete cascade,
  status        text not null default 'queued'
                check (status in ('queued', 'processing', 'succeeded', 'failed', 'cancelled')),
  preset        text not null default 'brand_background_v1',
  pipeline_ref  text,                               -- reference returned by the pipeline
  requested_by  uuid references users (id),
  requested_at  timestamptz not null default now(),
  started_at    timestamptz,
  finished_at   timestamptz,
  attempts      integer not null default 0,
  error         text
);
create index photo_jobs_status_idx on photo_jobs (status, requested_at);

create table vehicle_photos (
  id             uuid primary key default gen_random_uuid(),
  vehicle_id     uuid not null references vehicles (id) on delete cascade,
  photo_job_id   uuid references photo_jobs (id),
  angle          text not null check (angle in (
                   'front', 'front_left', 'left', 'rear_left', 'rear', 'rear_right', 'right', 'front_right',
                   'dashboard', 'front_seats', 'rear_seats', 'trunk', 'wheel', 'odometer', 'other')),
  original_path  text not null,
  processed_path text,                              -- written by the pipeline
  status         text not null default 'uploaded'
                 check (status in ('uploaded', 'processing', 'processed', 'approved', 'rejected')),
  sort_order     integer not null default 0,
  is_cover       boolean not null default false,
  uploaded_by    uuid references users (id),
  approved_by    uuid references users (id),
  created_at     timestamptz not null default now()
);
create index vehicle_photos_vehicle_idx on vehicle_photos (vehicle_id, sort_order);

-- ---------------------------------------------------------------- document links
alter table documents add column owner_id uuid references owners (id);
alter table documents add column vehicle_id uuid references vehicles (id);
create index documents_owner_idx on documents (owner_id);
create index documents_vehicle_idx on documents (vehicle_id);
