-- 0005_bookings.sql
-- Bookings with their price snapshot, drivers, per-booking fee terms, line items,
-- coverage proofs, deposits, payments, refunds, disputes, cancellations, extensions,
-- renewals, renter statements and the owner / company split.

create type booking_type as enum ('standard', 'non_refundable', 'owner');
create type booking_status as enum (
  'tentative',        -- 2-hour hold while the renter decides
  'pending_payment',  -- agreement sent for signature, checkout link sent
  'confirmed',        -- signed and paid
  'on_rent',          -- handed over
  'returned',         -- Check-in done; post-rental charges being assessed
  'closed',           -- statement issued, deposit settled
  'cancelled', 'no_show', 'expired', 'declined');

-- ---------------------------------------------------------------- bookings
create table bookings (
  id                    uuid primary key default gen_random_uuid(),
  booking_number        text not null unique,
  agreement_number      text unique,
  booking_type          booking_type not null default 'standard',
  renews_booking_id     uuid references bookings (id),     -- "Renewal of agreement no."
  status                booking_status not null default 'tentative',
  vehicle_id            uuid not null references vehicles (id),
  renter_id             uuid not null references renters (id),
  -- snapshot of who owns the vehicle and how it is managed, taken when the booking is made
  owner_id              uuid not null references owners (id),
  management_mode       management_mode not null,
  is_shareholder_vehicle boolean not null default false,
  company_share_bps     integer not null check (company_share_bps between 0 and 10000),
  source                text not null default 'web' check (source in ('web', 'phone', 'email', 'whatsapp', 'owner', 'staff')),
  booked_at             timestamptz not null default now(),      -- "made on"
  hold_expires_at       timestamptz,
  confirmed_at          timestamptz,
  pickup_at             timestamptz not null,                    -- the "start"
  return_at             timestamptz not null,                    -- current return time (after extensions)
  original_return_at    timestamptz not null,
  pickup_place          text,
  return_place          text,
  pickup_method         text not null default 'collected' check (pickup_method in ('collected', 'delivered')),
  return_method         text not null default 'returned' check (return_method in ('returned', 'picked_up')),
  billable_days         integer not null check (billable_days between 1 and 30),
  handed_over_at        timestamptz,
  checked_in_at         timestamptz,                             -- Check-in
  end_reason            text check (end_reason in ('normal', 'early_return', 'late_return', 'accident', 'theft', 'breach', 'repossession', 'breakdown')),
  -- price snapshot: a booking always uses the rates stored on it
  rate_card_id          uuid references rate_cards (id),
  daily_rate_cents      bigint not null check (daily_rate_cents >= 0),
  weekend_rate_cents    bigint not null check (weekend_rate_cents >= 0),
  weekly_rate_cents     bigint not null check (weekly_rate_cents >= 0),
  monthly_rate_cents    bigint not null check (monthly_rate_cents >= 0),
  rate_applied          text not null check (rate_applied in ('daily', 'weekly', 'monthly', 'none')),
  daily_days            integer not null default 0 check (daily_days >= 0),
  weekend_days          integer not null default 0 check (weekend_days >= 0),
  rental_charge_cents   bigint not null check (rental_charge_cents >= 0),  -- before the non-refundable discount
  discount_cents        bigint not null default 0 check (discount_cents >= 0),
  km_allowance_per_day  integer not null check (km_allowance_per_day >= 0),
  km_allowance_total    integer not null check (km_allowance_total >= 0),
  overage_cents_per_km  integer not null check (overage_cents_per_km >= 0),
  deposit_cents         bigint not null check (deposit_cents >= 0),
  deductible_cents      bigint not null default 250000,
  hst_bps               integer not null default 1300,
  subtotal_at_booking_cents bigint not null default 0,
  hst_at_booking_cents  bigint not null default 0,
  total_due_at_booking_cents bigint not null default 0,          -- the Deposit is taken at pickup, not here
  coverage_option       smallint check (coverage_option in (1, 2, 3)),
  coverage_confirmed_at timestamptz,
  card_on_file_id       uuid references payment_methods (id),
  referred_by_code      text,                                    -- "Referred by", captured before booking
  -- the code resolved to a person when the booking is made (never a virtual assistant)
  referrer_type         text check (referrer_type in ('owner', 'field_staff')),
  referrer_owner_id     uuid references owners (id),
  referrer_staff_id     uuid references users (id),
  -- Check-in readings
  odometer_out_km       integer,
  odometer_in_km        integer,
  fuel_out_pct          smallint check (fuel_out_pct between 0 and 100),
  fuel_in_pct           smallint check (fuel_in_pct between 0 and 100),
  minutes_late          integer check (minutes_late >= 0),
  extra_days            integer not null default 0 check (extra_days >= 0),
  unattended_handover   boolean not null default false,
  outside_ontario_consent boolean not null default false,
  pets_approved         boolean not null default false,
  agreement_document_id uuid references documents (id),
  signature_request_id  uuid references signature_requests (id),
  notes                 text,
  created_by            uuid references users (id),
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  rental_window         tstzrange generated always as (tstzrange(pickup_at, return_at, '[)')) stored,
  check (return_at > pickup_at),
  check (billable_days = public.calc_billable_days(pickup_at, return_at)),
  check (km_allowance_total = km_allowance_per_day * billable_days),
  check (booking_type = 'non_refundable' or discount_cents = 0),
  check (discount_cents <= rental_charge_cents),
  -- an Owner Rental has no rental charge, fee, Deposit or Coverage Option, and no split
  check (booking_type <> 'owner' or (rental_charge_cents = 0 and deposit_cents = 0 and company_share_bps = 0)),
  check (management_mode <> 'self_managed' or company_share_bps = 0),
  check (management_mode <> 'turo_only'),           -- Turo trips are not bookings (see turo_trips)
  check (renews_booking_id is null or renews_booking_id <> id),
  check ((referrer_type = 'owner') = (referrer_owner_id is not null)),
  check ((referrer_type = 'field_staff') = (referrer_staff_id is not null)),
  check (referrer_type is not null or (referrer_owner_id is null and referrer_staff_id is null)),
  -- a vehicle can hold only one live booking for any moment
  exclude using gist (vehicle_id with =, rental_window with &&)
    where (status in ('tentative', 'pending_payment', 'confirmed', 'on_rent'))
);
create index bookings_vehicle_idx on bookings (vehicle_id, pickup_at);
create index bookings_renter_idx on bookings (renter_id, pickup_at desc);
create index bookings_owner_idx on bookings (owner_id);
create index bookings_status_idx on bookings (status, pickup_at);
create index bookings_return_idx on bookings (return_at) where status = 'on_rent';
create index bookings_hold_idx on bookings (hold_expires_at) where status = 'tentative';
create unique index bookings_one_renewal on bookings (renews_booking_id) where renews_booking_id is not null and status not in ('cancelled', 'expired', 'declined');
create trigger bookings_updated before update on bookings for each row execute function app.set_updated_at();
create trigger audit_bookings after insert or update or delete on bookings
  for each row execute function app.audit_row();

alter table renters add constraint renters_first_booking_fk
  foreign key (first_completed_booking_id) references bookings (id);
alter table identity_verifications add constraint identity_verifications_booking_fk
  foreign key (booking_id) references bookings (id);
alter table consents add constraint consents_booking_fk
  foreign key (booking_id) references bookings (id);
alter table documents add column booking_id uuid references bookings (id);
create index documents_booking_idx on documents (booking_id);
create index identity_verifications_booking_idx on identity_verifications (booking_id);

-- ---------------------------------------------------------------- drivers on a booking
create table booking_drivers (
  id              uuid primary key default gen_random_uuid(),
  booking_id      uuid not null references bookings (id) on delete cascade,
  driver_id       uuid not null references drivers (id),
  role            text not null check (role in ('renter', 'additional')),
  -- snapshot as printed in the Summary
  full_name       text not null,
  date_of_birth   date not null,
  licence_number  text,
  licence_class   text,
  licence_issuer  text,
  licence_expiry  date,
  age_at_pickup   integer not null check (age_at_pickup >= 18),
  age_band        text not null check (age_band in ('18_to_20', '21_to_25', '26_plus')),
  identity_verification_id uuid references identity_verifications (id),
  identity_method text check (identity_method in ('identity_check_service', 'staff_review')),
  identity_verified_on date,
  signature_record_id uuid references signature_records (id),
  accepted_at     timestamptz,
  unique (booking_id, driver_id),
  check ((age_band = '18_to_20') = (age_at_pickup between 18 and 20)),
  check ((age_band = '21_to_25') = (age_at_pickup between 21 and 25))
);
create unique index booking_drivers_one_renter on booking_drivers (booking_id) where role = 'renter';
create index booking_drivers_driver_idx on booking_drivers (driver_id);

-- ---------------------------------------------------------------- per-booking fee terms (B)
-- Snapshot of every fee rate and cap that applies to this booking, with where it came from.
-- source = 'booking' is an admin's per-booking override.
create table booking_fee_terms (
  id             uuid primary key default gen_random_uuid(),
  booking_id     uuid not null references bookings (id) on delete cascade,
  fee_type_code  text not null references fee_types (code),
  amount_cents   bigint check (amount_cents >= 0),
  cap_cents      bigint check (cap_cents >= 0),
  percent_bps    integer check (percent_bps >= 0),
  source         text not null check (source in ('default', 'vehicle', 'booking')),
  override_by    uuid references users (id),
  override_reason text,
  created_at     timestamptz not null default now(),
  unique (booking_id, fee_type_code),
  check (source <> 'booking' or (override_by is not null and override_reason is not null))
);
create trigger audit_booking_fee_terms after insert or update or delete on booking_fee_terms
  for each row execute function app.audit_row();

-- ---------------------------------------------------------------- coverage proofs
create table coverage_proofs (
  id               uuid primary key default gen_random_uuid(),
  booking_id       uuid not null references bookings (id) on delete cascade,
  coverage_option  smallint not null check (coverage_option in (1, 2, 3)),
  status           text not null default 'submitted' check (status in ('submitted', 'confirmed', 'rejected', 'lapsed')),
  -- option 1: OPCF 27 on an active auto policy
  insurer_name     text,
  policy_number    text,
  policy_expiry    date,
  -- option 2: credit card rental coverage (the same card pays the rental and is Card on File)
  card_issuer      text,
  card_last4       text check (card_last4 ~ '^[0-9]{4}$'),
  -- option 3: purchased through CarmaCars (the provider is never named to the renter)
  terms_sent_at    timestamptz,
  activation_ref   text,
  activated_at     timestamptz,
  proof_document_id uuid references documents (id),
  covers_vehicle_and_drivers boolean,
  confirmed_by     uuid references users (id),
  confirmed_at     timestamptz,                     -- "Proof or activation confirmed"
  rejection_reason text,
  created_at       timestamptz not null default now(),
  check (status <> 'confirmed' or confirmed_at is not null),
  check (coverage_option <> 1 or status <> 'confirmed' or (insurer_name is not null and policy_number is not null and policy_expiry is not null)),
  check (coverage_option <> 2 or status <> 'confirmed' or (card_issuer is not null and card_last4 is not null)),
  check (coverage_option <> 3 or status <> 'confirmed' or activated_at is not null)
);
create index coverage_proofs_booking_idx on coverage_proofs (booking_id);

-- ---------------------------------------------------------------- payments
create table payments (
  id                uuid primary key default gen_random_uuid(),
  booking_id        uuid references bookings (id),
  renter_id         uuid references renters (id),
  owner_id          uuid references owners (id),
  owner_invoice_id  uuid,                           -- FK added in 0007
  purpose           text not null check (purpose in (
                      'booking_total', 'deposit', 'extension', 'post_rental', 'toll_ticket', 'damage', 'deductible',
                      'owner_upfront', 'owner_fees', 'other')),
  kind              text not null check (kind in ('charge', 'hold', 'capture', 'release', 'refund')),
  method            text not null default 'card' check (method in ('card', 'pre_authorized_debit', 'e_transfer', 'bank_transfer')),
  amount_cents      bigint not null check (amount_cents > 0),
  currency          text not null default 'CAD',
  status            text not null default 'pending'
                    check (status in ('pending', 'requires_action', 'authorized', 'succeeded', 'failed', 'cancelled')),
  parent_payment_id uuid references payments (id),  -- a capture, release or refund points at its hold or charge
  payment_method_id uuid references payment_methods (id),
  card_brand        text,
  card_last4        text,
  decline_count     integer not null default 0,
  last_decline_code text,
  next_retry_at     timestamptz,                    -- retries after 1, 3 and 7 days
  dispute_status    text not null default 'none' check (dispute_status in ('none', 'open', 'won', 'lost')),
  statement_sent_at timestamptz,
  processed_at      timestamptz,
  created_by        uuid references users (id),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  check (booking_id is not null or owner_id is not null)
);
create index payments_booking_idx on payments (booking_id);
create index payments_renter_idx on payments (renter_id);
create index payments_owner_idx on payments (owner_id);
create index payments_retry_idx on payments (next_retry_at) where status = 'failed' and next_retry_at is not null;
create trigger payments_updated before update on payments for each row execute function app.set_updated_at();
create trigger audit_payments after insert or update or delete on payments
  for each row execute function app.audit_row();

-- Full processor details: admin only (VAs see only the payments row above).
create table payment_processor_details (
  payment_id             uuid primary key references payments (id) on delete cascade,
  processor              text not null default 'stripe',
  processor_payment_id   text,                      -- payment intent
  processor_charge_id    text,
  processor_refund_id    text,
  processor_fee_cents    bigint,                    -- a company cost
  balance_transaction_id text,
  receipt_url            text,
  raw                    jsonb,
  unique (processor, processor_payment_id, processor_refund_id)
);

create table payment_attempts (
  id           uuid primary key default gen_random_uuid(),
  payment_id   uuid not null references payments (id) on delete cascade,
  attempt_no   integer not null check (attempt_no > 0),
  attempted_at timestamptz not null default now(),
  outcome      text not null check (outcome in ('succeeded', 'declined', 'error')),
  decline_code text,
  unique (payment_id, attempt_no)
);

-- ---------------------------------------------------------------- renter statements
create table booking_statements (
  id                    uuid primary key default gen_random_uuid(),
  booking_id            uuid not null references bookings (id),
  statement_number      text not null unique,
  kind                  text not null check (kind in ('check_in', 'later_charge', 'cancellation')),
  issued_at             timestamptz not null default now(),
  sent_at               timestamptz,
  charges_cents         bigint not null default 0,
  hst_cents             bigint not null default 0,
  deposit_applied_cents bigint not null default 0,
  held_back_cents       bigint not null default 0,
  deposit_returned_cents bigint not null default 0,
  charged_to_card_cents bigint not null default 0,
  interest_starts_on    date,                       -- 7 days after the statement
  paid_at               timestamptz,
  document_id           uuid references documents (id),
  created_by            uuid references users (id)
);
create index booking_statements_booking_idx on booking_statements (booking_id);

-- ---------------------------------------------------------------- extensions and renewals
create table booking_extensions (
  id                          uuid primary key default gen_random_uuid(),
  booking_id                  uuid not null references bookings (id) on delete cascade,
  seq                         integer not null check (seq > 0),
  status                      text not null default 'requested'
                              check (status in ('requested', 'confirmed', 'declined', 'lapsed')),
  requested_at                timestamptz not null default now(),
  previous_return_at          timestamptz not null,
  new_return_at               timestamptz not null,
  previous_days               integer not null,
  new_days                    integer not null check (new_days <= 30),  -- total length stays at 30 days or less
  previous_rental_charge_cents bigint not null,
  new_rental_charge_cents     bigint not null,       -- whole booking repriced at its new length, stored rates
  rental_difference_cents     bigint not null,
  fees_difference_cents       bigint not null default 0, -- per-day fees up to their caps
  hst_cents                   bigint not null default 0,
  total_cents                 bigint not null default 0,
  payment_id                  uuid references payments (id),
  paid_at                     timestamptz,
  confirmed_in_writing_at     timestamptz,           -- T11
  confirmed_by                uuid references users (id),
  deposit_hold_captured       boolean not null default false, -- total now over 7 days
  unique (booking_id, seq),
  check (new_return_at > previous_return_at),
  check (new_days > previous_days),
  -- valid only when confirmed in writing and paid before the return time
  check (status <> 'confirmed' or (paid_at is not null and confirmed_in_writing_at is not null
         and paid_at <= previous_return_at and confirmed_in_writing_at <= previous_return_at))
);

create table booking_renewals (
  id                    uuid primary key default gen_random_uuid(),
  previous_booking_id   uuid not null unique references bookings (id),
  new_booking_id        uuid not null unique references bookings (id),
  deposit_carried_cents bigint not null default 0,
  created_at            timestamptz not null default now(),
  check (previous_booking_id <> new_booking_id)
);

create table booking_vehicle_swaps (
  id              uuid primary key default gen_random_uuid(),
  booking_id      uuid not null references bookings (id) on delete cascade,
  from_vehicle_id uuid not null references vehicles (id),
  to_vehicle_id   uuid not null references vehicles (id),
  swapped_at      timestamptz not null default now(),
  reason          text not null,                    -- breakdown not the renter's fault, etc.
  approved_by     uuid references users (id)
);
create index booking_vehicle_swaps_booking_idx on booking_vehicle_swaps (booking_id);

-- ---------------------------------------------------------------- line items
create table booking_line_items (
  id                uuid primary key default gen_random_uuid(),
  booking_id        uuid not null references bookings (id) on delete cascade,
  charge_type       text not null references fee_types (code),
  description       text,
  quantity          numeric(12, 3) not null default 1,
  unit_amount_cents bigint not null,
  amount_cents      bigint not null,                -- before HST; negative for the discount
  hst_applies       boolean not null,
  hst_cents         bigint not null default 0,
  revenue_class     revenue_class not null,         -- "belongs to"
  charged_to_renter boolean not null default true,  -- false only for a booking expense (the kickback)
  stage             charge_stage not null,
  driver_id         uuid references drivers (id),   -- per-driver fees
  extension_id      uuid references booking_extensions (id),
  payment_id        uuid references payments (id),
  statement_id      uuid references booking_statements (id),
  supporting_document_id uuid references documents (id),
  incident_id       uuid,                           -- FKs added in 0008 / 0009
  toll_ticket_id    uuid,
  override_by       uuid references users (id),
  override_reason   text,
  voided_at         timestamptz,
  voided_by         uuid references users (id),
  void_reason       text,
  created_by        uuid references users (id),
  created_at        timestamptz not null default now(),
  check ((revenue_class = 'booking_expense') = (not charged_to_renter)),
  check (hst_applies or hst_cents = 0),
  check ((override_by is null) = (override_reason is null)),
  check ((voided_at is null) = (void_reason is null))
);
create index booking_line_items_booking_idx on booking_line_items (booking_id);
create index booking_line_items_payment_idx on booking_line_items (payment_id);
create index booking_line_items_class_idx on booking_line_items (revenue_class);
create trigger audit_booking_line_items after insert or update or delete on booking_line_items
  for each row execute function app.audit_row();

-- ---------------------------------------------------------------- deposits
create table deposits (
  id                 uuid primary key default gen_random_uuid(),
  booking_id         uuid not null unique references bookings (id) on delete cascade,
  amount_cents       bigint not null check (amount_cents >= 0),
  method             text not null check (method in ('card_hold', 'charged', 'carried_over')),
  status             text not null default 'pending'
                     check (status in ('pending', 'held', 'captured', 'settled', 'carried_forward', 'failed')),
  hold_payment_id    uuid references payments (id),
  taken_at           timestamptz,                   -- at pickup, before handover
  hold_expires_at    timestamptz,                   -- a card hold lapses after about 7 days
  captured_cents     bigint not null default 0 check (captured_cents >= 0),
  applied_cents      bigint not null default 0 check (applied_cents >= 0),   -- to Charges
  held_back_cents    bigint not null default 0 check (held_back_cents >= 0), -- pending claim, toll or ticket
  held_back_reason   text,
  held_back_until    date,                          -- up to 30 days after Check-in
  released_cents     bigint not null default 0 check (released_cents >= 0),
  release_due_on     date,                          -- 7 business days after Check-in
  released_at        timestamptz,
  release_approved_by uuid references users (id),  -- a deposit release is a payment: same limits as a refund
  carried_from_deposit_id uuid references deposits (id),
  carried_to_deposit_id   uuid references deposits (id),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  check (applied_cents + held_back_cents + released_cents <= amount_cents),
  check (held_back_cents = 0 or held_back_reason is not null),
  check (method <> 'carried_over' or carried_from_deposit_id is not null)
);
create trigger deposits_updated before update on deposits for each row execute function app.set_updated_at();

create table deposit_events (
  id           uuid primary key default gen_random_uuid(),
  deposit_id   uuid not null references deposits (id) on delete cascade,
  kind         text not null check (kind in ('taken', 'hold_renewed', 'captured', 'applied', 'held_back', 'released', 'carried_over', 'failed')),
  amount_cents bigint not null check (amount_cents >= 0),
  line_item_id uuid references booking_line_items (id),
  payment_id   uuid references payments (id),
  note         text,
  created_by   uuid references users (id),
  created_at   timestamptz not null default now()
);
create index deposit_events_deposit_idx on deposit_events (deposit_id, created_at);

-- ---------------------------------------------------------------- refunds
create table refunds (
  id                uuid primary key default gen_random_uuid(),
  booking_id        uuid not null references bookings (id),
  payment_id        uuid references payments (id),          -- the charge being refunded
  refund_payment_id uuid references payments (id),          -- the refund transaction
  reason            text not null check (reason in (
                      'cancellation', 'carmacars_cancelled', 'driver_not_verifiable', 'pricing_error',
                      'breakdown_unused_days', 'goodwill', 'duplicate', 'other')),
  refund_bps        integer check (refund_bps between 0 and 10000),
  amount_cents      bigint not null check (amount_cents >= 0),
  status            text not null default 'pending_approval'
                    check (status in ('pending_approval', 'approved', 'processing', 'paid', 'failed', 'rejected')),
  requested_by      uuid references users (id),
  approved_by       uuid references users (id),
  approved_at       timestamptz,
  due_by            date,                           -- 10 business days
  paid_at           timestamptz,
  note              text,
  created_at        timestamptz not null default now(),
  -- no refund moves without a named approver; who may approve what is enforced by
  -- app.guard_refund_approval() in 0012 (admin always; a finance VA only inside their Single Limit)
  check (status in ('pending_approval', 'rejected') or approved_by is not null)
);
create index refunds_booking_idx on refunds (booking_id);
create trigger audit_refunds after insert or update or delete on refunds
  for each row execute function app.audit_row();

-- The refund spread over the booking's lines in proportion, so each line's kept part is known.
create table refund_allocations (
  id           uuid primary key default gen_random_uuid(),
  refund_id    uuid not null references refunds (id) on delete cascade,
  line_item_id uuid not null references booking_line_items (id),
  amount_cents bigint not null,                     -- pre-HST part refunded
  hst_cents    bigint not null default 0,
  unique (refund_id, line_item_id)
);
create index refund_allocations_line_idx on refund_allocations (line_item_id);

create table booking_cancellations (
  booking_id        uuid primary key references bookings (id) on delete cascade,
  booked_at         timestamptz not null,
  received_at       timestamptz not null,           -- when the cancellation was received
  start_at          timestamptz not null,           -- pickup time in the Summary
  channel           text check (channel in ('portal', 'email', 'system')),
  cancelled_by      text not null check (cancelled_by in ('renter', 'carmacars', 'system')),
  reason            text not null check (reason in (
                      'renter_request', 'no_show', 'false_documents', 'no_coverage_at_pickup',
                      'carmacars_no_vehicle', 'driver_not_verifiable', 'pricing_error', 'other')),
  tier              text not null,
  refund_bps        integer not null check (refund_bps between 0 and 10000),
  total_paid_cents  bigint not null check (total_paid_cents >= 0),
  refund_cents      bigint not null check (refund_cents >= 0),
  retained_cents    bigint not null check (retained_cents >= 0),
  deposit_returned_cents bigint not null default 0, -- any Deposit already taken is returned in full
  refund_id         uuid references refunds (id),
  logged_by         uuid references users (id),
  created_at        timestamptz not null default now(),
  check (refund_cents + retained_cents = total_paid_cents)
);

-- ---------------------------------------------------------------- disputes (chargebacks)
create table disputes (
  id                  uuid primary key default gen_random_uuid(),
  payment_id          uuid not null references payments (id),
  booking_id          uuid references bookings (id),
  processor_dispute_ref text unique,
  amount_cents        bigint not null check (amount_cents > 0),
  reason              text,
  status              text not null default 'open' check (status in ('open', 'evidence_submitted', 'won', 'lost')),
  opened_at           timestamptz not null default now(),
  evidence_due_at     timestamptz,
  evidence_submitted_at timestamptz,
  evidence_document_ids uuid[] not null default '{}',  -- agreement, consents, Condition Report, Tracker data, statement
  owner_revenue_withheld_cents bigint not null default 0, -- withheld from the payout while open
  owner_revenue_reversed_cents bigint not null default 0, -- reversed if lost
  resolved_at         timestamptz,
  created_at          timestamptz not null default now()
);
create index disputes_booking_idx on disputes (booking_id);
create index disputes_open_idx on disputes (status) where status in ('open', 'evidence_submitted');

-- ---------------------------------------------------------------- split of a booking
create table booking_splits (
  booking_id            uuid primary key references bookings (id) on delete cascade,
  vehicle_id            uuid not null references vehicles (id),
  owner_id              uuid not null references owners (id),
  referrer_type         text check (referrer_type in ('owner', 'field_staff')),
  referrer_owner_id     uuid references owners (id),
  referrer_staff_id     uuid references users (id),
  is_first_rental       boolean not null default false,
  kickback_base_cents   bigint not null default 0,
  kickback_cents        bigint not null default 0 check (kickback_cents >= 0),
  rental_charge_cents   bigint not null default 0,   -- after discount and refunds, with late-return extra days
  mileage_overage_cents bigint not null default 0,
  owner_revenue_cents   bigint not null default 0,
  company_share_bps     integer not null check (company_share_bps between 0 and 10000),
  company_share_cents   bigint not null default 0,
  owner_payout_cents    bigint not null default 0,
  company_only_cents    bigint not null default 0,
  pass_through_cents    bigint not null default 0,
  hst_cents             bigint not null default 0,
  collected_cents       bigint not null default 0,
  refunded_cents        bigint not null default 0,
  chargeback_cents      bigint not null default 0,
  withheld_cents        bigint not null default 0,   -- Owner Revenue in dispute
  counts_on             date,                        -- the day the rental ends (or is cancelled)
  payout_month          date,                        -- first day of the statement month
  status                text not null default 'provisional' check (status in ('provisional', 'final', 'reversed')),
  owner_statement_id    uuid,                        -- FK added in 0007
  computed_at           timestamptz not null default now(),
  check (payout_month is null or extract(day from payout_month) = 1),
  check (owner_revenue_cents = rental_charge_cents + mileage_overage_cents - kickback_cents),
  check (owner_payout_cents = owner_revenue_cents - company_share_cents)
);
create index booking_splits_month_idx on booking_splits (vehicle_id, payout_month);
create index booking_splits_owner_idx on booking_splits (owner_id, payout_month);
