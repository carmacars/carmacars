-- 0019_booking_app.sql
-- What the public site and the renter portal need from the database to take a booking from a
-- visitor's first quote to a confirmed, signed and paid rental, and to look after it afterwards:
--
--   1. Browser access: thin functions in the public schema (the only schema the API exposes).
--   2. app.quote_booking(): the price a visitor sees, built by the same function that prices a
--      booking (app.price_lines), so a quote and a booking cannot disagree.
--   3. app.search_available(): listed cars that are free for the dates, with their total.
--   4. app.submit_booking_request(): the public request form, with its checks, its consents, an
--      idempotency key and rate limits. No card and no payment.
--   5. Signing built into the platform: rental_agreements, their signers, append-only signature
--      records, and the countersignature applied for CarmaCars.
--   6. Payment: webhook_events and app.record_booking_payment(), which confirms a booking under
--      a lock on the vehicle or tells the server to void the card authorization.
--   7. Renter self-service: cancellation, extensions, change requests on a confirmed booking,
--      and "more information needed" questions from staff.
--   8. Identity and coverage documents: registering uploads, staff review, the roll-up.
--   9. app.session_aal() and the two-step sign-in switch for staff.
--  10. Handover guards: additional drivers accepted, Deposit taken or waived by an Admin, the
--      calendar switch on.
--
-- Notes, decisions and assumptions: docs/changes/0019_booking_app.md.
--
-- No enum value is added here, so nothing in this file depends on the rule that a new enum
-- value cannot be used in the transaction that adds it. Money is integer cents, HST is per line,
-- business dates are Toronto dates.
--
-- Shared functions of earlier migrations replaced here (create or replace, same signature):
-- app.reprice_booking() of 0016, and app.is_admin(), app.va_has(), app.is_field() of 0012.
-- app.booking_before_write() is NOT replaced: the new checks on a booking are separate triggers.

-- ================================================================ settings
-- Every number the functions below use that an Admin may want to change is a column here (or a
-- fee default, a rate card or a per-booking fee term). A change is a new dated row, or an edit
-- of the row in force, from the admin portal.
alter table program_settings
  add column booking_min_notice_minutes   integer not null default 120 check (booking_min_notice_minutes >= 0),
  add column booking_request_hourly_limit integer not null default 5 check (booking_request_hourly_limit > 0),
  add column booking_open_request_limit   integer not null default 3 check (booking_open_request_limit > 0),
  add column public_rate_limit_per_minute integer not null default 0 check (public_rate_limit_per_minute >= 0),
  add column accepted_licence_classes     text[] not null default array['G', 'G2'],
  add column other_licence_for_review     boolean not null default true,
  add column max_additional_drivers       integer not null default 4 check (max_additional_drivers >= 0),
  add column max_baby_seats               integer not null default 3 check (max_baby_seats >= 0),
  add column request_note_max_chars       integer not null default 500 check (request_note_max_chars > 0),
  add column info_request_reply_hours     integer not null default 24 check (info_request_reply_hours > 0),
  add column verification_due_hours_before_pickup integer not null default 24 check (verification_due_hours_before_pickup >= 0),
  add column verification_review_hours    integer not null default 2 check (verification_review_hours > 0),
  add column require_staff_two_step       boolean not null default false;
comment on column program_settings.booking_min_notice_minutes is 'A request must ask for a pickup at least this many minutes from now.';
comment on column program_settings.booking_request_hourly_limit is 'Booking requests accepted per hour from one network address.';
comment on column program_settings.booking_open_request_limit is 'Requests one customer may have open (requested, offered or waiting for signature and payment) at one time.';
comment on column program_settings.public_rate_limit_per_minute is 'Quotes and availability searches one network address may ask for per minute from a browser. 0 turns the limit off (the default, until the address the API reports for a visitor has been checked in production).';
comment on column program_settings.accepted_licence_classes is 'Licence classes accepted on a request without review.';
comment on column program_settings.other_licence_for_review is 'When true, a licence from another province or country (class "other", with its issuer) is accepted on a request and flagged for staff to confirm.';
comment on column program_settings.max_additional_drivers is 'Additional drivers one request may name.';
comment on column program_settings.max_baby_seats is 'Baby seats one request may ask for.';
comment on column program_settings.request_note_max_chars is 'Longest note a customer may send with a request.';
comment on column program_settings.info_request_reply_hours is 'How long a customer has to answer a question from staff unless the question says otherwise.';
comment on column program_settings.verification_due_hours_before_pickup is 'Identity and coverage documents are due for review this many hours before pickup.';
comment on column program_settings.verification_review_hours is 'When the pickup is sooner than that, staff have this many hours to review an upload.';
comment on column program_settings.require_staff_two_step is 'When true, an admin, virtual assistant or field staff session without two-step sign-in (assurance level aal2) has no staff access at all. Off until every staff member has enrolled.';

-- ================================================================ bookings: the request snapshot and the Deposit waiver
alter table bookings
  add column request_key           text unique check (length(request_key) between 8 and 100),
  add column request_details       jsonb,
  add column awaiting_renter_since timestamptz,
  add column deposit_waived_at     timestamptz,
  add column deposit_waived_by     uuid references users (id),
  add column deposit_waived_reason text,
  add column deposit_waived_cents  bigint check (deposit_waived_cents >= 0);
alter table bookings
  add constraint bookings_deposit_waiver check (
    deposit_waived_at is null or (deposit_waived_by is not null and btrim(coalesce(deposit_waived_reason, '')) <> ''));
comment on column bookings.request_key is 'Made by the browser when the request form is opened. A second submit with the same key returns the first booking.';
comment on column bookings.request_details is 'The request as the customer sent it: drivers, extras, coverage choice, consents, where they came from. When set, app.reprice_booking() keeps the per-driver and extras fee lines in step with it.';
comment on column bookings.awaiting_renter_since is 'Set while a question from staff to the renter is unanswered (booking_info_requests).';
comment on column bookings.deposit_waived_at is 'An Admin waived the Deposit for this booking, with a reason. The car may then be handed over without one. deposit_waived_cents keeps the amount that was waived; deposit_cents becomes 0.';

-- ================================================================ extensions: the step between asking and paying
do $$
declare
  c text;
begin
  select conname into strict c from pg_constraint
   where conrelid = 'public.booking_extensions'::regclass and contype = 'c'
     and pg_get_constraintdef(oid) like '%lapsed%' and pg_get_constraintdef(oid) not like '%paid_at%';
  execute format('alter table public.booking_extensions drop constraint %I', c);
end $$;
alter table booking_extensions
  add constraint booking_extensions_status_check check (status in ('requested', 'approved', 'confirmed', 'declined', 'lapsed')),
  add column requested_by   uuid references users (id),
  add column note           text,
  add column lines          jsonb,              -- the price difference, line by line, as shown to the renter
  add column approved_by    uuid references users (id),
  add column approved_at    timestamptz,
  add column declined_by    uuid references users (id),
  add column declined_at    timestamptz,
  add column decline_reason text;
create unique index booking_extensions_one_open on booking_extensions (booking_id) where status in ('requested', 'approved');

-- ================================================================ consents: the two the request form adds
-- The list of consent codes is a check constraint. It is rebuilt from what is there now plus the
-- two new codes, so a code added by another migration is kept. (The list is read in either of
-- the two ways PostgreSQL may print it, and written back as a plain "in" list.)
do $$
declare
  c record;
  v_codes text[];
begin
  select conname, pg_get_constraintdef(oid) as def into strict c from pg_constraint
   where conrelid = 'public.consents'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%consent_code%';
  select array_agg(distinct m[1]) into v_codes from regexp_matches(c.def, '[''{,]([a-z_]+)(?=[''},])', 'g') m;
  select array_agg(distinct x order by x) into v_codes from unnest(v_codes || array['terms_of_use', 'privacy_policy']) x;
  execute format('alter table public.consents drop constraint %I', c.conname);
  execute format('alter table public.consents add constraint consents_consent_code_check check (consent_code in (%s))',
                 (select string_agg(quote_literal(x), ', ') from unnest(v_codes) x));
end $$;

-- ================================================================ signature records: what was typed and agreed to
alter table signature_records
  add column if not exists typed_name      text,
  add column if not exists consent_text    text,
  add column if not exists document_sha256 text;
comment on column signature_records.consent_text is 'The statement the signer agreed to when signing, word for word.';
comment on column signature_records.document_sha256 is 'SHA-256 of the rendered document that was on screen when this signature was given.';

-- ================================================================ rental agreements signed in the platform
create sequence rental_agreement_number_seq start 20001;

create table rental_agreements (
  id                    uuid primary key default gen_random_uuid(),
  booking_id            uuid not null references bookings (id) on delete cascade,
  offer_version         integer,                 -- the approved offer this agreement is for; null on an Owner Booking
  agreement_number      text not null,
  template_version      text not null,           -- the exact version of the agreement text
  document_id           uuid not null references documents (id),
  document_sha256       text not null check (document_sha256 ~ '^[0-9a-f]{64}$'),  -- of the rendered document, supplied by the server
  signature_request_id  uuid not null unique references signature_requests (id),
  status                text not null default 'open' check (status in (
                          'open',        -- waiting for the renter
                          'signed',      -- the renter has signed; not yet paid and countersigned
                          'completed',   -- countersigned by CarmaCars: the booking is confirmed
                          'voided')),    -- the offer changed or ended before completion: sign again
  countersigner_user_id uuid references users (id),  -- the staff member who sent the offer
  countersigner_name    text not null,
  opened_by             uuid references users (id),
  opened_at             timestamptz not null default now(),
  renter_signed_at      timestamptz,
  completed_at          timestamptz,
  voided_at             timestamptz,
  void_reason           text,
  check (status <> 'voided' or (voided_at is not null and void_reason is not null)),
  check (status <> 'completed' or completed_at is not null),
  check (status not in ('signed', 'completed') or renter_signed_at is not null)
);
create unique index rental_agreements_one_live on rental_agreements (booking_id) where status in ('open', 'signed', 'completed');
create index rental_agreements_booking_idx on rental_agreements (booking_id, opened_at);
comment on table rental_agreements is 'One row each time a rental agreement is opened for signature on a booking. A booking has at most one that is not voided.';

create table rental_agreement_signers (
  id                      uuid primary key default gen_random_uuid(),
  agreement_id            uuid not null references rental_agreements (id) on delete cascade,
  signer_role             text not null check (signer_role in ('renter', 'additional_driver', 'carmacars')),
  booking_driver_id       uuid references booking_drivers (id),
  driver_id               uuid references drivers (id),
  user_id                 uuid references users (id),
  signer_name             text not null,
  signer_email            text,
  required_before_payment boolean not null default false,  -- the renter; additional drivers accept separately, before handover
  signature_record_id     uuid references signature_records (id),
  signed_at               timestamptz,
  created_at              timestamptz not null default now(),
  check ((signature_record_id is null) = (signed_at is null))
);
create unique index rental_agreement_signers_one_renter on rental_agreement_signers (agreement_id) where signer_role = 'renter';
create unique index rental_agreement_signers_one_company on rental_agreement_signers (agreement_id) where signer_role = 'carmacars';
create unique index rental_agreement_signers_one_per_driver on rental_agreement_signers (agreement_id, driver_id) where driver_id is not null;
create index rental_agreement_signers_user_idx on rental_agreement_signers (user_id);
comment on table rental_agreement_signers is 'Who must sign one rental agreement. The signature itself is a signature_records row, which is never changed.';

-- A signature on a rental agreement is append-only: it is written once, signed, and never
-- changed or removed. (Other documents keep the behaviour they had.)
create or replace function app.guard_signature_record() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if exists (select 1 from rental_agreements a where a.signature_request_id = old.signature_request_id) then
    raise exception '% on a rental agreement signature is not allowed: a signature record is append-only', tg_op
      using errcode = '42501';
  end if;
  return coalesce(new, old);
end $$;
create trigger signature_records_append_only before update or delete on signature_records
  for each row execute function app.guard_signature_record();

-- ================================================================ payment processor events, each handled once
create table webhook_events (
  id           uuid primary key default gen_random_uuid(),
  provider     text not null,
  event_id     text not null,                    -- the provider's own id for the event
  event_type   text,
  booking_id   uuid references bookings (id),
  summary      jsonb not null default '{}'::jsonb,  -- ids and amounts only; never the provider's full payload
  received_at  timestamptz not null default now(),
  processed_at timestamptz,
  result       jsonb,
  error        text,
  unique (provider, event_id)
);
comment on table webhook_events is 'One row per event received from a payment processor. The unique provider event id is what makes a webhook safe to receive twice.';

-- ================================================================ changes to a confirmed booking
create table booking_change_requests (
  id                 uuid primary key default gen_random_uuid(),
  booking_id         uuid not null references bookings (id) on delete cascade,
  requested_by_role  text not null check (requested_by_role in ('renter', 'staff')),
  requested_by       uuid references users (id),
  status             text not null default 'requested' check (status in (
                       'requested',   -- the renter asked; staff have not answered
                       'proposed',    -- staff proposed it; the renter has not agreed
                       'approved',    -- staff approved it, priced; waiting for the renter's agreement or the money
                       'declined', 'cancelled', 'applied')),
  note               text,
  changes            jsonb not null,             -- what was asked for: pickup_at, return_at, vehicle_id
  before             jsonb,                      -- the booking when it was last priced
  after              jsonb,                      -- the booking as it would be
  lines              jsonb,                      -- the price after the change, line by line
  difference_cents   bigint,                     -- before HST; negative when the renter is owed money
  hst_cents          bigint,
  total_difference_cents bigint,
  priced_at          timestamptz,
  decided_by         uuid references users (id),
  decided_at         timestamptz,
  decline_reason     text,
  renter_agreed_at   timestamptz,
  agreed_by_phone    boolean not null default false,
  agreed_note        text,
  agreed_by          uuid references users (id),
  agreed_ip          inet,
  agreed_user_agent  text,
  payment_id         uuid references payments (id),
  refund_id          uuid references refunds (id),
  applied_by         uuid references users (id),
  applied_at         timestamptz,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  check (status <> 'declined' or decline_reason is not null),
  check (status <> 'applied' or applied_at is not null),
  check (not agreed_by_phone or agreed_note is not null)
);
create unique index booking_change_requests_one_open on booking_change_requests (booking_id) where status in ('requested', 'proposed', 'approved');
create index booking_change_requests_booking_idx on booking_change_requests (booking_id, created_at);
create trigger booking_change_requests_updated before update on booking_change_requests
  for each row execute function app.set_updated_at();

-- ================================================================ "more information needed" on a request
create table booking_info_requests (
  id          uuid primary key default gen_random_uuid(),
  booking_id  uuid not null references bookings (id) on delete cascade,
  question    text not null check (btrim(question) <> ''),
  asked_by    uuid not null references users (id),
  asked_at    timestamptz not null default now(),
  reply_by    timestamptz not null,
  status      text not null default 'open' check (status in ('open', 'answered', 'closed')),
  reply       text,
  replied_by  uuid references users (id),
  replied_at  timestamptz,
  closed_reason text,
  check (reply_by > asked_at),
  check (status <> 'answered' or (reply is not null and replied_at is not null))
);
create index booking_info_requests_booking_idx on booking_info_requests (booking_id, asked_at);

-- ================================================================ identity and coverage uploads, reviewed one by one
create table verification_uploads (
  id                       uuid primary key default gen_random_uuid(),
  booking_id               uuid not null references bookings (id) on delete cascade,
  driver_id                uuid references drivers (id),        -- null for the coverage proof, which belongs to the booking
  kind                     text not null check (kind in ('licence_front', 'licence_back', 'selfie', 'coverage_proof')),
  document_id              uuid not null references documents (id),
  status                   text not null default 'submitted' check (status in ('submitted', 'approved', 'rejected', 'replaced')),
  reject_reason            text,
  identity_verification_id uuid references identity_verifications (id),
  coverage_proof_id        uuid references coverage_proofs (id),
  uploaded_by              uuid references users (id),
  uploaded_at              timestamptz not null default now(),
  reviewed_by              uuid references users (id),
  reviewed_at              timestamptz,
  check ((kind = 'coverage_proof') = (driver_id is null)),
  check (status <> 'rejected' or (reject_reason is not null and reviewed_by is not null)),
  check (status <> 'approved' or reviewed_by is not null)
);
create unique index verification_uploads_one_current on verification_uploads (booking_id, coalesce(driver_id, booking_id), kind)
  where status in ('submitted', 'approved');
create index verification_uploads_booking_idx on verification_uploads (booking_id);
comment on table verification_uploads is 'Each licence front, licence back, selfie and coverage proof a renter registers, with the staff decision on it. The file itself is a documents row in private storage.';

-- ================================================================ rate limits
-- A counter, not a record: it lives in the app schema, outside the API and the audit log
-- (an audit row per hit would be noise). Old rows are removed by app.rate_limit_purge().
create table app.rate_limit_hits (
  key           text not null,
  window_start  timestamptz not null,
  window_length interval not null,
  hits          integer not null default 0,
  last_hit_at   timestamptz not null default now(),
  primary key (key, window_start)
);
create index rate_limit_hits_age_idx on app.rate_limit_hits (window_start);

comment on table app.rate_limit_hits is 'Counters for app.rate_limit(). One row per key and window.';

-- ================================================================ small additions to existing tables
-- The booking history gains the kinds this migration writes. The list is a check constraint; it
-- is rebuilt from what is there now plus the new kinds, so a kind added by another migration is kept.
do $$
declare
  c record;
  v_kinds text[];
begin
  select conname, pg_get_constraintdef(oid) as def into strict c from pg_constraint
   where conrelid = 'public.booking_events'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%kind%';
  select array_agg(distinct m[1]) into v_kinds from regexp_matches(c.def, '[''{,]([a-z_]+)(?=[''},])', 'g') m;
  select array_agg(distinct x order by x) into v_kinds
    from unnest(v_kinds || array['agreement_opened', 'agreement_signed', 'agreement_completed', 'agreement_voided', 'confirmed',
                                 'payment_refused', 'info_requested', 'info_replied', 'cancelled', 'extension', 'booking_change',
                                 'verification', 'deposit_waived']) x;
  execute format('alter table public.booking_events drop constraint %I', c.conname);
  execute format('alter table public.booking_events add constraint booking_events_kind_check check (kind in (%s))',
                 (select string_agg(quote_literal(x), ', ') from unnest(v_kinds) x));
end $$;

-- Named in the blueprint's list for this group; "if not exists" because the operations work may add the same columns.
alter table signature_requests add column if not exists in_person boolean not null default false;
alter table reviews
  add column if not exists publish_consent_at timestamptz,
  add column if not exists google_prompt_clicked_at timestamptz;
comment on column signature_requests.in_person is 'Signed on a staff member''s device with the signer present (a Condition Report at the door).';

-- ================================================================ rate limits
-- True while the key has been used no more than p_max times in the current window. Windows are
-- fixed (the hour, the minute), counted from a fixed origin, so two callers agree on them.
-- The count is part of the caller's transaction: a caller that must keep the count when it
-- refuses returns a result instead of raising an error (app.submit_booking_request does).
create or replace function app.rate_limit(p_key text, p_max integer, p_window interval) returns boolean
language plpgsql security definer set search_path = public, app as $$
declare
  v_start timestamptz;
  v_hits integer;
begin
  if p_key is null or btrim(p_key) = '' or p_max is null or p_max < 1 or p_window is null or p_window <= interval '0' then
    raise exception 'A rate limit needs a key, a maximum of at least 1 and a window' using errcode = '22023';
  end if;
  v_start := date_bin(p_window, now(), timestamptz '2000-01-01 00:00:00+00');
  insert into app.rate_limit_hits as h (key, window_start, window_length, hits)
  values (p_key, v_start, p_window, 1)
  on conflict (key, window_start) do update set hits = h.hits + 1, last_hit_at = now()
  returning h.hits into v_hits;
  if v_hits = 1 then
    -- the first hit of a new window clears this key's earlier windows
    delete from app.rate_limit_hits where key = p_key and window_start < v_start;
  end if;
  return v_hits <= p_max;
end $$;

-- Removes counters nobody will read again. Called by the retention job; safe at any time.
create or replace function app.rate_limit_purge(p_older_than interval default interval '2 days') returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  n integer;
begin
  delete from app.rate_limit_hits where window_start + window_length < now() - p_older_than;
  get diagnostics n = row_count;
  return n;
end $$;

-- The visitor's network address as the API reports it in the request headers, or null (the
-- server, a job, a test). Used only for the optional limit on public quotes and searches.
create or replace function app.request_ip() returns inet
language plpgsql stable as $$
declare
  h jsonb;
  v text;
begin
  h := nullif(current_setting('request.headers', true), '')::jsonb;
  v := coalesce(nullif(btrim(h ->> 'cf-connecting-ip'), ''), nullif(btrim(split_part(h ->> 'x-forwarded-for', ',', 1)), ''));
  return v::inet;
exception when others then
  return null;
end $$;

-- The limit on quotes and availability searches asked for straight from a browser. Does nothing
-- for the server, when the setting is 0, or when no address is known.
create or replace function app.public_rate_check(p_action text) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  v_max integer := coalesce((app.settings()).public_rate_limit_per_minute, 0);
  v_ip inet;
begin
  if v_max = 0 or coalesce(pg_catalog.current_setting('role', true), '') not in ('anon', 'authenticated') then
    return;
  end if;
  v_ip := app.request_ip();
  if v_ip is null then return; end if;
  if not app.rate_limit(p_action || ':ip:' || host(v_ip), v_max, interval '1 minute') then
    raise exception 'Too many requests. Please wait a minute and try again.' using errcode = '53400';
  end if;
end $$;

-- ================================================================ two-step sign-in for staff
-- The assurance level of the session, from the sign-in token: 'aal1' after a password or link,
-- 'aal2' after a second factor. Null when there is no token (the server, a job).
create or replace function app.session_aal() returns text
language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claim.aal', true), ''),
                  nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'aal')
$$;
comment on function app.session_aal() is 'Reads the sign-in assurance level from the token claims, through the same seam as app.uid().';

-- True when this session may act as staff: always while the switch is off; with the switch on,
-- only a session that passed the second factor.
create or replace function app.staff_two_step_ok() returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce(app.session_aal() = 'aal2', false) or not coalesce((app.settings()).require_staff_two_step, false)
$$;

-- The three staff helpers of migration 0012, each with the two-step condition added. Every
-- staff policy, limited view and guard reads one of them, so with the switch on a staff session
-- without the second factor reads and writes nothing as staff. Customers are not affected.
create or replace function app.is_admin() returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.has_role('admin') and app.staff_two_step_ok()
$$;

create or replace function app.va_has(variadic p_functions text[] default '{}') returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.has_role('va') and exists (
    select 1 from staff_profiles sp
     where sp.user_id = app.uid() and sp.staff_type = 'va' and sp.is_active
       and (cardinality(p_functions) = 0 or sp.va_function::text = any (p_functions)))
     and app.staff_two_step_ok()
$$;

create or replace function app.is_field() returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.has_role('field') and exists (
    select 1 from staff_profiles sp where sp.user_id = app.uid() and sp.staff_type = 'field' and sp.is_active)
     and app.staff_two_step_ok()
$$;

-- ================================================================ who is acting (by user id), continued
-- An active virtual assistant holding one of the named functions. For the server, which acts
-- for a named user (app.va_has() is the same question about the browser session).
create or replace function app.user_va_has(p_user uuid, variadic p_functions text[]) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (
    select 1 from user_roles r join users u on u.id = r.user_id
      join staff_profiles sp on sp.user_id = r.user_id and sp.staff_type = 'va' and sp.is_active
     where r.user_id = p_user and r.role = 'va' and u.status = 'active' and sp.va_function::text = any (p_functions))
$$;

-- Age in whole years on a date, and the age band the fees and the booking_drivers table use.
create or replace function app.age_on(p_date_of_birth date, p_on date) returns integer
language sql immutable as $$ select extract(year from age(p_on, p_date_of_birth))::integer $$;

create or replace function app.age_band(p_age integer) returns text
language sql immutable as $$
  select case when p_age between 18 and 20 then '18_to_20' when p_age between 21 and 25 then '21_to_25' when p_age >= 26 then '26_plus' end
$$;
comment on function app.age_band(integer) is 'The bands are fixed by the check constraints of booking_drivers (migration 0005) and by the two young driver charge types.';

-- ================================================================ one source for prices
-- app.price_lines() works out every charge line of a booking from one description of it (the
-- "spec"). A quote builds the spec from the rate card in force and what the visitor chose; a
-- booking builds it from the rates and terms stored on the booking. Both then call the same
-- function, so a quote and a booking with the same facts always give the same lines.

-- One fee as it applies to a booking: the booking's own term if it has one (booking_fee_terms,
-- the snapshot taken at the request, or an Admin's per-booking change), otherwise the vehicle's
-- override, otherwise the admin default.
create or replace function app.fee_term(p_fee text, p_vehicle uuid, p_on date, p_booking uuid default null)
returns table (amount_cents bigint, cap_cents bigint, percent_bps integer, source text)
language plpgsql stable security definer set search_path = public, app as $$
begin
  if p_booking is not null then
    return query select t.amount_cents, t.cap_cents, t.percent_bps, t.source
                   from booking_fee_terms t where t.booking_id = p_booking and t.fee_type_code = p_fee;
    if found then return; end if;
  end if;
  return query select e.amount_cents, e.cap_cents, e.percent_bps, e.source from public.effective_fee(p_fee, p_vehicle, p_on) e;
end $$;

-- One charge line, classified and taxed from the charge catalogue.
create or replace function app.price_line(p_code text, p_quantity numeric, p_unit_cents bigint, p_amount_cents bigint, p_hst_bps integer,
                                          p_description text default null, p_driver uuid default null, p_detail jsonb default null)
returns jsonb language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
           'charge_type', f.code, 'label', f.label, 'description', coalesce(p_description, f.label),
           'quantity', p_quantity, 'unit_amount_cents', p_unit_cents, 'amount_cents', p_amount_cents,
           'hst_applies', f.hst_applies,
           'hst_cents', case when f.hst_applies then public.calc_hst(p_amount_cents, p_hst_bps) else 0 end,
           'revenue_class', f.revenue_class, 'driver_id', p_driver, 'detail', coalesce(p_detail, '{}'::jsonb),
           'sort_order', f.sort_order)
    from fee_types f where f.code = p_code
$$;

-- The spec (every key optional unless marked):
--   pickup_at, return_at (required), booking_type ('standard', 'non_refundable', 'owner'), hst_bps,
--   daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents,
--   rental_charge_cents          a rental charge set by hand; otherwise the rate rule decides
--   non_refundable_discount_bps, staff_discount_cents, promo_code_id,
--   delivery_fee_cents, pickup_fee_cents   the fee to charge, 0 or absent for none
--   managed                      true: also work out the per-driver, extras and coverage lines
--   drivers                      [{driver_id, role ('renter', 'additional'), age_band, name}]
--   extras                       {winter_tire: true, baby_seats: 2}
--   coverage_option              1, 2 or 3 (3 adds the coverage line once it has a price)
--   fee_terms                    {charge type: {amount_cents, cap_cents}} for the per-day fees and coverage
-- Returns the days, the rate rule that applied, the discounts, the lines and the totals.
create or replace function app.price_lines(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_type text := coalesce(p ->> 'booking_type', 'standard');
  v_pickup timestamptz := (p ->> 'pickup_at')::timestamptz;
  v_return timestamptz := (p ->> 'return_at')::timestamptz;
  v_hst integer := coalesce((p ->> 'hst_bps')::integer, 0);
  v_daily bigint := coalesce((p ->> 'daily_rate_cents')::bigint, 0);
  v_weekend bigint := coalesce((p ->> 'weekend_rate_cents')::bigint, 0);
  v_weekly bigint := coalesce((p ->> 'weekly_rate_cents')::bigint, 0);
  v_monthly bigint := coalesce((p ->> 'monthly_rate_cents')::bigint, 0);
  v_days integer;
  r record;
  v_uncapped bigint;
  v_capped boolean := false;
  v_rule text;
  v_rental bigint;
  v_discount bigint := 0;
  v_staff bigint := 0;
  v_promo bigint := 0;
  v_lines jsonb := '[]'::jsonb;
  d jsonb;
  t jsonb;
  v_code text;
  v_rate bigint;
  v_cap bigint;
  v_amt bigint;
  n integer;
  v_sub bigint;
  v_tax bigint;
begin
  if v_pickup is null or v_return is null or v_return <= v_pickup then
    raise exception 'The return must be after the pickup' using errcode = '22023';
  end if;
  v_days := public.calc_billable_days(v_pickup, v_return);
  -- (also refuses a length outside 1 to 30 days)
  select * into r from public.calc_rental_charge(v_pickup, v_days, v_daily, v_weekend, v_weekly, v_monthly);

  if v_type = 'owner' then
    -- an Owner Booking has no rental charge, fee or Deposit
    return jsonb_build_object('billable_days', v_days, 'rate_applied', 'none', 'daily_days', r.daily_days, 'weekend_days', r.weekend_days,
      'rate_rule', 'Owner Booking: nothing to pay', 'rate_capped', false, 'rental_charge_cents', 0,
      'non_refundable_discount_cents', 0, 'staff_discount_cents', 0, 'promo_discount_cents', 0,
      'lines', '[]'::jsonb, 'subtotal_cents', 0, 'hst_bps', v_hst, 'hst_cents', 0, 'total_cents', 0);
  end if;

  -- which rate applied, and whether its cap did (renter billing specification section 2)
  if r.rate_applied = 'daily' then
    v_uncapped := r.daily_days * v_daily + r.weekend_days * v_weekend;
    v_capped := v_uncapped > v_weekly;
    v_rule := concat_ws(' and ',
                case when r.daily_days > 0 then format('%s day%s at the daily rate', r.daily_days, case when r.daily_days = 1 then '' else 's' end) end,
                case when r.weekend_days > 0 then format('%s day%s at the weekend rate', r.weekend_days, case when r.weekend_days = 1 then '' else 's' end) end)
              || case when v_capped then ', capped at the weekly rate' else '' end;
  elsif r.rate_applied = 'weekly' then
    v_uncapped := round(v_weekly::numeric * v_days / 7)::bigint;
    v_capped := v_uncapped > v_monthly;
    v_rule := format('weekly rate divided by 7, times %s days', v_days) || case when v_capped then ', capped at the monthly rate' else '' end;
  else
    v_uncapped := v_monthly;
    v_rule := 'monthly rate';
  end if;

  v_rental := coalesce((p ->> 'rental_charge_cents')::bigint, r.rental_charge_cents);
  if (p ->> 'rental_charge_cents') is not null and v_rental <> r.rental_charge_cents then
    v_rule := 'rental charge set for this booking';
    v_capped := false;
  end if;
  if v_type = 'non_refundable' then
    v_discount := public.calc_bps(v_rental, coalesce((p ->> 'non_refundable_discount_bps')::integer, 0));
  end if;
  v_staff := coalesce((p ->> 'staff_discount_cents')::bigint, 0);
  if (p ->> 'promo_code_id') is not null then
    v_promo := coalesce(app.promo_discount_cents((p ->> 'promo_code_id')::uuid, v_rental - v_discount - v_staff), 0);
  end if;

  if v_rental <> 0 then
    v_lines := v_lines || app.price_line('rental_charge', 1, v_rental, v_rental, v_hst, null, null,
      jsonb_build_object('rate_applied', r.rate_applied, 'rate_rule', v_rule, 'capped', v_capped, 'billable_days', v_days,
                         'daily_days', r.daily_days, 'weekend_days', r.weekend_days));
  end if;
  if v_discount <> 0 then
    v_lines := v_lines || app.price_line('non_refundable_discount', 1, -v_discount, -v_discount, v_hst);
  end if;
  if v_staff <> 0 then
    v_lines := v_lines || app.price_line('staff_discount', 1, -v_staff, -v_staff, v_hst);
  end if;
  if v_promo <> 0 then
    v_lines := v_lines || app.price_line('promo_discount', 1, -v_promo, -v_promo, v_hst);
  end if;
  v_amt := coalesce((p ->> 'delivery_fee_cents')::bigint, 0);
  if v_amt <> 0 then
    v_lines := v_lines || app.price_line('delivery', 1, v_amt, v_amt, v_hst);
  end if;
  v_amt := coalesce((p ->> 'pickup_fee_cents')::bigint, 0);
  if v_amt <> 0 then
    v_lines := v_lines || app.price_line('pickup', 1, v_amt, v_amt, v_hst);
  end if;

  if coalesce((p ->> 'managed')::boolean, false) then
    -- per driver: the young driver fee of their age band, and the additional driver fee;
    -- each is per day up to its cap per rental
    for d in select value from jsonb_array_elements(coalesce(p -> 'drivers', '[]'::jsonb)) loop
      if d ->> 'age_band' in ('18_to_20', '21_to_25') then
        v_code := case d ->> 'age_band' when '18_to_20' then 'young_driver_18_20' else 'young_driver_21_25' end;
        t := p -> 'fee_terms' -> v_code;
        v_rate := (t ->> 'amount_cents')::bigint;
        v_cap := (t ->> 'cap_cents')::bigint;
        if coalesce(v_rate, 0) > 0 then
          v_amt := public.calc_capped_per_day(v_rate, v_days, v_cap);
          v_lines := v_lines || app.price_line(v_code, v_days, v_rate, v_amt, v_hst,
            (select f.label || coalesce(': ' || nullif(d ->> 'name', ''), '') from fee_types f where f.code = v_code),
            (d ->> 'driver_id')::uuid,
            jsonb_build_object('driver_name', d ->> 'name', 'age_band', d ->> 'age_band', 'per_day_cents', v_rate, 'cap_cents', v_cap,
                               'capped', v_amt < v_rate * v_days));
        end if;
      end if;
      if d ->> 'role' = 'additional' then
        t := p -> 'fee_terms' -> 'additional_driver';
        v_rate := (t ->> 'amount_cents')::bigint;
        v_cap := (t ->> 'cap_cents')::bigint;
        if coalesce(v_rate, 0) > 0 then
          v_amt := public.calc_capped_per_day(v_rate, v_days, v_cap);
          v_lines := v_lines || app.price_line('additional_driver', v_days, v_rate, v_amt, v_hst,
            (select f.label || coalesce(': ' || nullif(d ->> 'name', ''), '') from fee_types f where f.code = 'additional_driver'),
            (d ->> 'driver_id')::uuid,
            jsonb_build_object('driver_name', d ->> 'name', 'per_day_cents', v_rate, 'cap_cents', v_cap, 'capped', v_amt < v_rate * v_days));
        end if;
      end if;
    end loop;
    -- extras
    if coalesce((p -> 'extras' ->> 'winter_tire')::boolean, false) then
      t := p -> 'fee_terms' -> 'winter_tire';
      v_rate := (t ->> 'amount_cents')::bigint;
      v_cap := (t ->> 'cap_cents')::bigint;
      if coalesce(v_rate, 0) > 0 then
        v_amt := public.calc_capped_per_day(v_rate, v_days, v_cap);
        v_lines := v_lines || app.price_line('winter_tire', v_days, v_rate, v_amt, v_hst, null, null,
          jsonb_build_object('per_day_cents', v_rate, 'cap_cents', v_cap, 'capped', v_amt < v_rate * v_days));
      end if;
    end if;
    n := coalesce((p -> 'extras' ->> 'baby_seats')::integer, 0);
    if n > 0 then
      t := p -> 'fee_terms' -> 'baby_seat';
      v_rate := (t ->> 'amount_cents')::bigint;
      v_cap := (t ->> 'cap_cents')::bigint;
      if coalesce(v_rate, 0) > 0 then
        v_amt := public.calc_capped_per_day(v_rate, v_days, v_cap, n);
        v_lines := v_lines || app.price_line('baby_seat', n, public.calc_capped_per_day(v_rate, v_days, v_cap), v_amt, v_hst, null, null,
          jsonb_build_object('seats', n, 'per_day_cents', v_rate, 'cap_cents', v_cap, 'capped', v_amt < v_rate * v_days * n));
      end if;
    end if;
    -- coverage bought through CarmaCars: a line only once an Admin has set its price
    if (p ->> 'coverage_option') = '3' then
      v_rate := (p -> 'fee_terms' -> 'coverage_sold' ->> 'amount_cents')::bigint;
      if coalesce(v_rate, 0) > 0 then
        v_lines := v_lines || app.price_line('coverage_sold', 1, v_rate, v_rate, v_hst);
      end if;
    end if;
  end if;

  select coalesce(jsonb_agg(x.value order by (x.value ->> 'sort_order')::integer, x.ord), '[]'::jsonb),
         coalesce(sum((x.value ->> 'amount_cents')::bigint), 0), coalesce(sum((x.value ->> 'hst_cents')::bigint), 0)
    into v_lines, v_sub, v_tax
    from jsonb_array_elements(v_lines) with ordinality x(value, ord);

  return jsonb_build_object('billable_days', v_days, 'rate_applied', r.rate_applied, 'daily_days', r.daily_days, 'weekend_days', r.weekend_days,
    'rate_rule', v_rule, 'rate_capped', v_capped, 'rental_charge_cents', v_rental,
    'non_refundable_discount_cents', v_discount, 'staff_discount_cents', v_staff, 'promo_discount_cents', v_promo,
    'lines', v_lines, 'subtotal_cents', v_sub, 'hst_bps', v_hst, 'hst_cents', v_tax, 'total_cents', v_sub + v_tax);
end $$;

-- The spec of a booking as it stands, or as it would stand with other dates or another vehicle
-- (p_changes: pickup_at, return_at, vehicle_id; also rental_charge_cents to price with a given
-- rental charge, recompute_rental to let the rate rule decide, managed to work out the
-- per-driver and extras lines whatever the booking carries). The rates are always the ones
-- stored on the booking. With the dates unchanged the rental charge is the one stored on the
-- booking (which an Admin may have set by hand); with other dates the rate rule decides.
create or replace function app.booking_price_spec(p_booking uuid, p_changes jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  rc rate_cards;
  v_set program_settings;
  v_on date;
  v_vehicle uuid;
  v_pickup timestamptz;
  v_return timestamptz;
  v_delivery bigint;
  v_pickup_fee bigint;
  v_drivers jsonb;
  v_terms jsonb;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null then raise exception 'Booking % not found', p_booking; end if;
  v_on := app.local_date(b.booked_at);
  v_set := app.settings(v_on);
  v_vehicle := coalesce((p_changes ->> 'vehicle_id')::uuid, b.vehicle_id);
  v_pickup := coalesce((p_changes ->> 'pickup_at')::timestamptz, b.pickup_at);
  v_return := coalesce((p_changes ->> 'return_at')::timestamptz, b.return_at);
  select * into rc from rate_cards r
   where r.vehicle_id = v_vehicle and r.effective_from <= now() and (r.effective_to is null or r.effective_to > now());

  -- delivery and pickup: the fee already on the booking if there is one (staff may have set
  -- it), otherwise the rate card's; none when the booking does not call for it
  select li.amount_cents into v_delivery from booking_line_items li
   where li.booking_id = p_booking and li.charge_type = 'delivery' and li.stage = 'booking' and li.voided_at is null
   order by li.created_at, li.id limit 1;
  select li.amount_cents into v_pickup_fee from booking_line_items li
   where li.booking_id = p_booking and li.charge_type = 'pickup' and li.stage = 'booking' and li.voided_at is null
   order by li.created_at, li.id limit 1;
  v_delivery := case when b.pickup_method <> 'delivered' then 0 else coalesce(v_delivery, rc.delivery_fee_cents, 0) end;
  v_pickup_fee := case when b.return_method <> 'picked_up' then 0 else coalesce(v_pickup_fee, rc.pickup_fee_cents, 0) end;

  select coalesce(jsonb_agg(jsonb_build_object('driver_id', d.driver_id, 'role', d.role, 'name', d.full_name,
                    'age_band', app.age_band(app.age_on(d.date_of_birth, app.local_date(v_pickup))))
                  order by d.role desc, d.full_name, d.id), '[]'::jsonb)
    into v_drivers from booking_drivers d where d.booking_id = p_booking;
  select coalesce(jsonb_object_agg(c.code, jsonb_build_object('amount_cents', t.amount_cents, 'cap_cents', t.cap_cents, 'source', t.source)), '{}'::jsonb)
    into v_terms
    from unnest(array['young_driver_18_20', 'young_driver_21_25', 'additional_driver', 'winter_tire', 'baby_seat', 'coverage_sold']) c(code)
    cross join lateral app.fee_term(c.code, v_vehicle, v_on, p_booking) t;

  return jsonb_build_object(
    'vehicle_id', v_vehicle, 'pickup_at', v_pickup, 'return_at', v_return, 'booking_type', b.booking_type, 'hst_bps', b.hst_bps,
    'daily_rate_cents', b.daily_rate_cents, 'weekend_rate_cents', b.weekend_rate_cents,
    'weekly_rate_cents', b.weekly_rate_cents, 'monthly_rate_cents', b.monthly_rate_cents,
    'rental_charge_cents', case when (p_changes ->> 'rental_charge_cents') is not null then (p_changes ->> 'rental_charge_cents')::bigint
                                when coalesce((p_changes ->> 'recompute_rental')::boolean, false) then null
                                when v_pickup = b.pickup_at and v_return = b.return_at then b.rental_charge_cents end,
    'non_refundable_discount_bps', v_set.non_refundable_discount_bps,
    'staff_discount_cents', b.staff_discount_cents, 'promo_code_id', b.promo_code_id,
    'delivery_fee_cents', v_delivery, 'pickup_fee_cents', v_pickup_fee,
    'managed', b.request_details is not null or coalesce((p_changes ->> 'managed')::boolean, false),
    'drivers', v_drivers, 'extras', coalesce(b.request_details -> 'extras', '{}'::jsonb),
    'coverage_option', b.coverage_option, 'fee_terms', v_terms);
end $$;

-- Write one priced line onto a booking: created, or changed when its amount moved. A line is
-- matched by its charge type and its driver. Returns the line's id.
create or replace function app.put_price_line(p_booking uuid, p_line jsonb) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_line booking_line_items;
  v_driver uuid := (p_line ->> 'driver_id')::uuid;
  v_id uuid;
begin
  select * into v_line from booking_line_items
   where booking_id = p_booking and charge_type = p_line ->> 'charge_type' and stage = 'booking' and voided_at is null
     and driver_id is not distinct from v_driver
   order by created_at, id limit 1;
  if v_line.id is null then
    insert into booking_line_items (booking_id, charge_type, description, quantity, unit_amount_cents, amount_cents,
                                    hst_applies, hst_cents, revenue_class, stage, driver_id)
    values (p_booking, p_line ->> 'charge_type', p_line ->> 'description', (p_line ->> 'quantity')::numeric,
            (p_line ->> 'unit_amount_cents')::bigint, (p_line ->> 'amount_cents')::bigint,
            (p_line ->> 'hst_applies')::boolean, (p_line ->> 'hst_cents')::bigint, (p_line ->> 'revenue_class')::revenue_class,
            'booking', v_driver)
    returning id into v_id;
    return v_id;
  end if;
  if (v_line.amount_cents, v_line.hst_cents, v_line.unit_amount_cents, v_line.quantity)
     is distinct from ((p_line ->> 'amount_cents')::bigint, (p_line ->> 'hst_cents')::bigint,
                       (p_line ->> 'unit_amount_cents')::bigint, (p_line ->> 'quantity')::numeric(12, 3)) then
    update booking_line_items
       set unit_amount_cents = (p_line ->> 'unit_amount_cents')::bigint, amount_cents = (p_line ->> 'amount_cents')::bigint,
           quantity = (p_line ->> 'quantity')::numeric, hst_cents = (p_line ->> 'hst_cents')::bigint
     where id = v_line.id;
  end if;
  return v_line.id;
end $$;

-- Bring a booking's price lines and totals in step with the booking, whatever its status.
-- Internal: app.reprice_booking() adds the rule about when a price may still move.
--   Always kept in step: the rental charge and its three discounts, delivery and pickup.
--   Kept in step when the booking carries its request (request_details): the young driver fee
--   and the additional driver fee per driver, winter tire, baby seat and coverage sold.
--   Any other line is left as staff entered it. Lines are voided, never deleted.
create or replace function app.sync_booking_price(p_booking uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_out jsonb;
  v_promo bigint;
  v_owned text[] := array['rental_charge', 'non_refundable_discount', 'staff_discount', 'promo_discount', 'delivery', 'pickup'];
  v_keep uuid[] := '{}';
  l jsonb;
  v_sub bigint; v_hst bigint;
  s record;
begin
  select * into b from bookings where id = p_booking for update;
  if b.id is null then raise exception 'Booking % not found', p_booking; end if;
  v_out := app.price_lines(app.booking_price_spec(p_booking));

  v_promo := (v_out ->> 'promo_discount_cents')::bigint;
  if v_promo is distinct from b.promo_discount_cents then
    update bookings set promo_discount_cents = v_promo where id = p_booking;
    update promo_redemptions set discount_cents = v_promo where booking_id = p_booking and status <> 'released';
  end if;

  if b.booking_type <> 'owner' then
    if b.request_details is not null then
      v_owned := v_owned || array['young_driver_18_20', 'young_driver_21_25', 'additional_driver', 'winter_tire', 'baby_seat', 'coverage_sold'];
    end if;
    for l in select value from jsonb_array_elements(v_out -> 'lines') loop
      v_keep := v_keep || app.put_price_line(p_booking, l);
    end loop;
    update booking_line_items set voided_at = now(), void_reason = 'no longer applies'
     where booking_id = p_booking and stage = 'booking' and voided_at is null
       and charge_type = any (v_owned) and id <> all (v_keep);
  end if;

  select coalesce(sum(amount_cents), 0), coalesce(sum(hst_cents), 0) into v_sub, v_hst
    from booking_line_items
   where booking_id = p_booking and stage = 'booking' and charged_to_renter and voided_at is null;
  select * into s from app.booking_insurer_share(p_booking);
  update bookings
     set subtotal_at_booking_cents = v_sub, hst_at_booking_cents = v_hst, total_due_at_booking_cents = v_sub + v_hst,
         insurer_share_cents = least(s.share_cents, greatest(v_sub, 0)),
         insurer_hst_cents = least(s.hst_cents, greatest(v_hst, 0))
   where id = p_booking;
end $$;

-- Replaces the function of migration 0016 (same name, same rule about when a price may move:
-- while the booking is a request, or while its dates are provisional). The lines now come from
-- app.price_lines(), the function a quote uses.
create or replace function app.reprice_booking(p_booking uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
begin
  select * into b from bookings where id = p_booking for update;
  if b.id is null then raise exception 'Booking % not found', p_booking; end if;
  if not (b.status in ('requested', 'tentative') or (b.dates_provisional and b.status in ('confirmed', 'on_rent'))) then
    raise exception 'Booking % is % and its price is settled', b.booking_number, b.status using errcode = '23514';
  end if;
  perform app.sync_booking_price(p_booking);
end $$;

-- ================================================================ the quote
-- The price of one vehicle for the dates and choices given, line by line. Internal: no check on
-- who is asking (app.quote_booking and app.search_available add theirs).
-- p_options: booking_type ('standard' or 'non_refundable'), pickup_method ('collected' or
-- 'delivered'), return_method ('returned' or 'picked_up'), drivers [{role, date_of_birth or age
-- or age_band, name}] (the first is the renter unless a role says otherwise; none given: one
-- renter aged 26 or over), extras {winter_tire, baby_seats}, coverage_option (1, 2 or 3),
-- promo_code.
create or replace function app.price_quote(p_vehicle uuid, p_pickup timestamptz, p_return timestamptz, p_options jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = public, app as $$
declare
  o jsonb := coalesce(p_options, '{}'::jsonb);
  v vehicles;
  rc rate_cards;
  v_set program_settings := app.settings();
  v_type text := coalesce(o ->> 'booking_type', 'standard');
  v_on date := app.local_date(p_pickup);
  v_drivers jsonb := '[]'::jsonb;
  v_problems jsonb := '[]'::jsonb;
  d jsonb;
  i integer := 0;
  v_age integer;
  v_band text;
  v_role text;
  v_additional integer := 0;
  v_terms jsonb;
  v_promo_id uuid;
  v_promo_problem text;
  v_cover integer := (o ->> 'coverage_option')::integer;
  v_cover_price bigint;
  v_seats integer := coalesce((o -> 'extras' ->> 'baby_seats')::integer, 0);
  v_out jsonb;
  v_days integer;
begin
  select * into v from vehicles where id = p_vehicle;
  if v.id is null then raise exception 'Vehicle not found' using errcode = '22023'; end if;
  if v_type not in ('standard', 'non_refundable') then
    raise exception 'A quote is for a standard or a non-refundable booking' using errcode = '22023';
  end if;
  select * into rc from rate_cards r
   where r.vehicle_id = p_vehicle and r.effective_from <= now() and (r.effective_to is null or r.effective_to > now());
  if rc.id is null then raise exception 'This vehicle has no rates set' using errcode = '23514'; end if;

  for d in select value from jsonb_array_elements(case when jsonb_typeof(o -> 'drivers') = 'array' then o -> 'drivers' else '[]'::jsonb end) loop
    i := i + 1;
    v_role := coalesce(d ->> 'role', case when i = 1 then 'renter' else 'additional' end);
    v_age := case when (d ->> 'date_of_birth') is not null then app.age_on((d ->> 'date_of_birth')::date, v_on) else (d ->> 'age')::integer end;
    v_band := case when v_age is not null then app.age_band(v_age) else coalesce(d ->> 'age_band', '26_plus') end;
    if v_role = 'additional' then v_additional := v_additional + 1; end if;
    if v_age is not null and v_age < v_set.min_renter_age then
      v_problems := v_problems || jsonb_build_object('code', 'driver_under_minimum_age', 'driver', i,
        'message', format('Every driver must be %s or older at pickup.', v_set.min_renter_age));
    elsif v_band = '18_to_20' and not v.allows_18_to_20 then
      v_problems := v_problems || jsonb_build_object('code', 'vehicle_not_for_young_drivers', 'driver', i,
        'message', format('This car is for drivers %s and over.', v_set.standard_min_age));
    end if;
    v_drivers := v_drivers || jsonb_build_object('driver_id', d ->> 'driver_id', 'role', v_role, 'name', d ->> 'name', 'age', v_age, 'age_band', v_band);
  end loop;
  if i = 0 then
    v_drivers := jsonb_build_array(jsonb_build_object('role', 'renter', 'age_band', '26_plus', 'assumed', true));
  end if;
  if v_additional > v_set.max_additional_drivers then
    v_problems := v_problems || jsonb_build_object('code', 'too_many_additional_drivers',
      'message', format('A booking may name up to %s additional drivers.', v_set.max_additional_drivers));
  end if;
  if v_seats > v_set.max_baby_seats then
    v_problems := v_problems || jsonb_build_object('code', 'too_many_baby_seats',
      'message', format('A booking may ask for up to %s baby seats.', v_set.max_baby_seats));
  end if;
  if v.exit_date is not null and app.local_date(p_return) > v.exit_date then
    v_problems := v_problems || jsonb_build_object('code', 'vehicle_leaving', 'message', 'This car is not offered for the whole of these dates.');
  end if;

  select coalesce(jsonb_object_agg(c.code, jsonb_build_object('amount_cents', t.amount_cents, 'cap_cents', t.cap_cents, 'source', t.source)), '{}'::jsonb)
    into v_terms
    from unnest(array['young_driver_18_20', 'young_driver_21_25', 'additional_driver', 'winter_tire', 'baby_seat', 'coverage_sold']) c(code)
    cross join lateral app.fee_term(c.code, p_vehicle, app.today()) t;
  v_cover_price := (v_terms -> 'coverage_sold' ->> 'amount_cents')::bigint;
  if v_cover = 3 and coalesce(v_cover_price, 0) = 0 then
    v_problems := v_problems || jsonb_build_object('code', 'coverage_not_sold_yet', 'message', 'Coverage through CarmaCars is not available yet. Choose your own auto policy or your credit card''s rental coverage.');
  end if;

  if nullif(btrim(o ->> 'promo_code'), '') is not null then
    v_promo_problem := app.promo_code_problem(o ->> 'promo_code', app.my_renter_id());
    if v_promo_problem is null then
      select id into v_promo_id from promo_codes where code = upper(btrim(o ->> 'promo_code'));
    end if;
  end if;

  v_out := app.price_lines(jsonb_build_object(
    'vehicle_id', p_vehicle, 'pickup_at', p_pickup, 'return_at', p_return, 'booking_type', v_type, 'hst_bps', v_set.hst_bps,
    'daily_rate_cents', rc.daily_rate_cents, 'weekend_rate_cents', rc.weekend_rate_cents,
    'weekly_rate_cents', rc.weekly_rate_cents, 'monthly_rate_cents', rc.monthly_rate_cents,
    'non_refundable_discount_bps', v_set.non_refundable_discount_bps, 'promo_code_id', v_promo_id,
    'delivery_fee_cents', case when o ->> 'pickup_method' = 'delivered' then rc.delivery_fee_cents else 0 end,
    'pickup_fee_cents', case when o ->> 'return_method' = 'picked_up' then rc.pickup_fee_cents else 0 end,
    'managed', true, 'drivers', v_drivers, 'extras', coalesce(o -> 'extras', '{}'::jsonb),
    'coverage_option', v_cover, 'fee_terms', v_terms));
  v_days := (v_out ->> 'billable_days')::integer;
  if v_days > v_set.max_rental_days then
    raise exception 'A rental transaction is 1 to % days; % requested. Longer stays renew with a new booking.', v_set.max_rental_days, v_days
      using errcode = '22023';
  end if;

  return (v_out - 'lines') || jsonb_build_object(
    'vehicle_id', p_vehicle, 'pickup_at', p_pickup, 'return_at', p_return, 'booking_type', v_type, 'currency', 'CAD',
    -- the visitor sees each line and its tax, not which part belongs to whom
    'lines', (select coalesce(jsonb_agg((x.value - 'revenue_class' - 'sort_order') order by x.ord), '[]'::jsonb)
                from jsonb_array_elements(v_out -> 'lines') with ordinality x(value, ord)),
    'rates', jsonb_build_object('rate_card_id', rc.id, 'daily_rate_cents', rc.daily_rate_cents, 'weekend_rate_cents', rc.weekend_rate_cents,
                                'weekly_rate_cents', rc.weekly_rate_cents, 'monthly_rate_cents', rc.monthly_rate_cents),
    'total_due_at_booking_cents', (v_out ->> 'total_cents')::bigint,
    'deposit_cents', rc.deposit_cents,
    'deposit_method', public.calc_deposit_method(v_days, v_set.deposit_hold_max_days),
    'km_allowance_per_day', rc.km_allowance_per_day, 'km_allowance_total', rc.km_allowance_per_day * v_days,
    'overage_cents_per_km', rc.overage_cents_per_km,
    'coverage', jsonb_build_object('option', v_cover, 'sold_by_carmacars_available', coalesce(v_cover_price, 0) > 0,
                                   'sold_by_carmacars_price_cents', v_cover_price,
                                   'note', 'Proof of coverage is confirmed after booking and before pickup.'),
    'promo', case when nullif(btrim(o ->> 'promo_code'), '') is not null
                  then jsonb_build_object('code', upper(btrim(o ->> 'promo_code')), 'applied', v_promo_id is not null, 'problem', v_promo_problem) end,
    'drivers', v_drivers,
    'available', app.vehicle_is_available(p_vehicle, p_pickup, p_return),
    'problems', v_problems);
end $$;

-- The quote a browser asks for. A visitor or a customer may price only a car on the public
-- listing; staff and the server may price any car that has rates.
create or replace function app.quote_booking(p_vehicle uuid, p_pickup timestamptz, p_return timestamptz, p_options jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public, app as $$
begin
  perform app.public_rate_check('quote');
  if coalesce(pg_catalog.current_setting('role', true), '') in ('anon', 'authenticated') and not app.is_staff()
     and not exists (select 1 from public_vehicle_listings l where l.vehicle_id = p_vehicle) then
    raise exception 'This car is not available to book' using errcode = '22023';
  end if;
  return app.price_quote(p_vehicle, p_pickup, p_return, p_options);
end $$;

-- Listed cars that are free for the whole of the dates, each with its total for those dates,
-- cheapest first. p_filters: class or classes [..], seats_min, transmission, fuel, make,
-- young (true: only cars offered to drivers aged 18 to 20), max_daily_rate_cents,
-- max_total_cents, and options (the same options as a quote, applied to every car).
create or replace function app.search_available(p_pickup timestamptz, p_return timestamptz, p_filters jsonb default '{}'::jsonb)
returns table (vehicle_id uuid, slug text, vehicle_year smallint, make text, model text, vehicle_class text, seats smallint,
               transmission text, fuel text, allows_18_to_20 boolean, daily_rate_cents bigint, billable_days integer,
               rental_charge_cents bigint, subtotal_cents bigint, hst_cents bigint, total_cents bigint, deposit_cents bigint)
language plpgsql security definer set search_path = public, app as $$
#variable_conflict use_column
declare
  f jsonb := coalesce(p_filters, '{}'::jsonb);
  v_set program_settings := app.settings();
  v_days integer;
begin
  perform app.public_rate_check('search');
  if p_pickup is null or p_return is null or p_return <= p_pickup then
    raise exception 'The return must be after the pickup' using errcode = '22023';
  end if;
  v_days := public.calc_billable_days(p_pickup, p_return);
  if v_days > v_set.max_rental_days then
    raise exception 'A rental transaction is 1 to % days; % requested. Longer stays renew with a new booking.', v_set.max_rental_days, v_days
      using errcode = '22023';
  end if;
  return query
    select q.vehicle_id, q.slug, q.year, q.make, q.model, q.class, q.seats, q.transmission, q.fuel, q.allows_18_to_20, q.daily_rate_cents,
           (q.quote ->> 'billable_days')::integer, (q.quote ->> 'rental_charge_cents')::bigint, (q.quote ->> 'subtotal_cents')::bigint,
           (q.quote ->> 'hst_cents')::bigint, (q.quote ->> 'total_cents')::bigint, q.deposit_cents
      from (select l.vehicle_id, l.slug, l.year, l.make, l.model, l.class::text as class, l.seats, l.transmission, l.fuel::text as fuel,
                   l.allows_18_to_20, l.daily_rate_cents, l.deposit_cents,
                   app.price_quote(l.vehicle_id, p_pickup, p_return, coalesce(f -> 'options', '{}'::jsonb)) as quote
              from public_vehicle_listings l
              join vehicles v on v.id = l.vehicle_id
             where app.vehicle_is_available(l.vehicle_id, p_pickup, p_return)
               and (v.exit_date is null or app.local_date(p_return) <= v.exit_date)
               and ((f ->> 'class') is null or l.class::text = f ->> 'class')
               and (jsonb_typeof(f -> 'classes') is distinct from 'array' or l.class::text in (select jsonb_array_elements_text(f -> 'classes')))
               and ((f ->> 'seats_min') is null or l.seats >= (f ->> 'seats_min')::integer)
               and ((f ->> 'transmission') is null or lower(l.transmission) = lower(f ->> 'transmission'))
               and ((f ->> 'fuel') is null or l.fuel::text = f ->> 'fuel')
               and ((f ->> 'make') is null or lower(l.make) = lower(f ->> 'make'))
               and (not coalesce((f ->> 'young')::boolean, false) or l.allows_18_to_20)
               and ((f ->> 'max_daily_rate_cents') is null or l.daily_rate_cents <= (f ->> 'max_daily_rate_cents')::bigint)) q
     where (f ->> 'max_total_cents') is null or (q.quote ->> 'total_cents')::bigint <= (f ->> 'max_total_cents')::bigint
     order by (q.quote ->> 'total_cents')::bigint, q.slug, q.vehicle_id;
end $$;

-- ================================================================ the public request
-- A visitor (or a signed-in customer) asks for a car. Called by the server after its own
-- checks (the bot check and the visitor's network address are things only the server knows).
-- One transaction: finds or creates the user, the renter and the drivers; checks ages, the
-- licence, the dates and the limits; creates the request through app.request_booking(); stores
-- the drivers, the chosen coverage option, the extras, the note, the consents and the request
-- itself; snapshots the fee terms; and prices everything, per-driver and extras lines included.
-- No card and no payment.
--
-- p_request:
--   request_key     made by the browser when the form opens; a second submit with it returns the first booking
--   vehicle_id, pickup_at, return_at, booking_type ('standard' or 'non_refundable'),
--   pickup_method, return_method, pickup_place, return_place,
--   renter          {full_name, date_of_birth, email, mobile, licence_class, licence_issuer, user_id}
--                   (user_id: the id of the sign-in account the server made for a new customer)
--   additional_drivers  [{full_name, date_of_birth, email, licence_class, licence_issuer}]
--   extras          {winter_tire, baby_seats}
--   coverage_option 1, 2 or 3
--   note, referred_by_code, promo_code,
--   consents        {terms: {accepted, version, text}, privacy: {accepted, version, text},
--                    marketing: {opted_in, version, text}}
--   details         anything else worth keeping (similar car accepted, outside Ontario, pet, where they came from)
-- p_user: the signed-in user, when there is one. Their own record is used, whatever the form says.
--
-- Returns {ok: true, created, booking_id, booking_number, ...}; or, when a limit refuses the
-- request, {ok: false, error: 'rate_limited' or 'too_many_open_requests'} with nothing written
-- but the count. Anything wrong with the request itself raises an error.
create or replace function app.submit_booking_request(p_request jsonb, p_ip inet default null, p_user_agent text default null,
                                                      p_user uuid default null)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  q jsonb := coalesce(p_request, '{}'::jsonb);
  r jsonb := coalesce(p_request -> 'renter', '{}'::jsonb);
  c jsonb := coalesce(p_request -> 'consents', '{}'::jsonb);
  v_set program_settings := app.settings();
  v_key text := btrim(coalesce(p_request ->> 'request_key', ''));
  b bookings;
  v vehicles;
  u users;
  rn renters;
  dr drivers;
  v_vehicle uuid := (p_request ->> 'vehicle_id')::uuid;
  v_pickup timestamptz := (p_request ->> 'pickup_at')::timestamptz;
  v_return timestamptz := (p_request ->> 'return_at')::timestamptz;
  v_type text := coalesce(p_request ->> 'booking_type', 'standard');
  v_pickup_method text := coalesce(p_request ->> 'pickup_method', 'collected');
  v_return_method text := coalesce(p_request ->> 'return_method', 'returned');
  v_note text := nullif(btrim(coalesce(p_request ->> 'note', '')), '');
  v_cover integer := (p_request ->> 'coverage_option')::integer;
  v_seats integer := coalesce((p_request -> 'extras' ->> 'baby_seats')::integer, 0);
  v_email text := lower(btrim(coalesce(p_request -> 'renter' ->> 'email', '')));
  v_name text := nullif(btrim(coalesce(p_request -> 'renter' ->> 'full_name', '')), '');
  v_mobile text := nullif(btrim(coalesce(p_request -> 'renter' ->> 'mobile', '')), '');
  v_dob date := (p_request -> 'renter' ->> 'date_of_birth')::date;
  v_class text := upper(nullif(btrim(coalesce(p_request -> 'renter' ->> 'licence_class', '')), ''));
  v_issuer text := nullif(btrim(coalesce(p_request -> 'renter' ->> 'licence_issuer', '')), '');
  v_on date;
  v_days integer;
  v_age integer;
  v_band text;
  v_new_account boolean := false;
  v_uid uuid;
  v_review boolean := false;
  v_differ boolean := false;
  v_conflict boolean;
  v_promo_problem text;
  v_booking uuid;
  v_adds jsonb := case when jsonb_typeof(p_request -> 'additional_drivers') = 'array' then p_request -> 'additional_drivers' else '[]'::jsonb end;
  a jsonb;
  v_a_name text; v_a_dob date; v_a_email text; v_a_class text; v_a_issuer text; v_a_age integer;
  v_driver uuid;
  v_drivers_kept jsonb := '[]'::jsonb;
  v_names text[] := '{}';
  v_details jsonb;
begin
  -- the key, and a second submit
  if length(v_key) not between 8 and 100 then
    raise exception 'A request needs its request key (8 to 100 characters)' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('carmacars:booking_request:' || v_key, 0));
  select * into b from bookings where request_key = v_key;
  if b.id is not null then
    return jsonb_build_object('ok', true, 'created', false, 'booking_id', b.id, 'booking_number', b.booking_number,
                              'status', b.status, 'renter_id', b.renter_id);
  end if;

  -- spam: so many requests an hour from one network address
  if p_ip is not null and not app.rate_limit('booking_request:ip:' || host(p_ip), v_set.booking_request_hourly_limit, interval '1 hour') then
    return jsonb_build_object('ok', false, 'error', 'rate_limited',
                              'message', 'Too many requests from this connection. Please try again later or call us.');
  end if;

  -- the trip
  if v_vehicle is null or not exists (select 1 from public_vehicle_listings l where l.vehicle_id = v_vehicle) then
    raise exception 'This car is not available to book' using errcode = '23514';
  end if;
  select * into v from vehicles where id = v_vehicle;
  if v_pickup is null or v_return is null or v_return <= v_pickup then
    raise exception 'The return must be after the pickup' using errcode = '22023';
  end if;
  if v_pickup < now() + make_interval(mins => v_set.booking_min_notice_minutes) then
    raise exception 'The pickup must be at least % minutes from now', v_set.booking_min_notice_minutes using errcode = '22023';
  end if;
  v_days := public.calc_billable_days(v_pickup, v_return);
  if v_days > v_set.max_rental_days then
    raise exception 'A rental transaction is 1 to % days; % requested. Longer stays renew with a new booking.', v_set.max_rental_days, v_days
      using errcode = '22023';
  end if;
  if v_type not in ('standard', 'non_refundable') then
    raise exception 'A request is for a standard or a non-refundable booking' using errcode = '22023';
  end if;
  if v_pickup_method not in ('collected', 'delivered') or v_return_method not in ('returned', 'picked_up') then
    raise exception 'Unknown pickup or return method' using errcode = '22023';
  end if;
  if v_pickup_method = 'delivered' and nullif(btrim(coalesce(p_request ->> 'pickup_place', '')), '') is null then
    raise exception 'A delivery needs its address' using errcode = '22023';
  end if;
  if v_return_method = 'picked_up' and nullif(btrim(coalesce(p_request ->> 'return_place', '')), '') is null then
    raise exception 'A pickup at the end of the rental needs its address' using errcode = '22023';
  end if;
  if length(coalesce(v_note, '')) > v_set.request_note_max_chars then
    raise exception 'The note is too long (at most % characters)', v_set.request_note_max_chars using errcode = '22023';
  end if;
  if v_seats < 0 or v_seats > v_set.max_baby_seats then
    raise exception 'A booking may ask for up to % baby seats', v_set.max_baby_seats using errcode = '22023';
  end if;
  if v_cover is null or v_cover not in (1, 2, 3) then
    raise exception 'Choose how damage to the car will be covered (option 1, 2 or 3)' using errcode = '22023';
  end if;
  if v_cover = 3 and coalesce((select t.amount_cents from app.fee_term('coverage_sold', v_vehicle, app.today()) t), 0) = 0 then
    raise exception 'Coverage through CarmaCars is not available yet' using errcode = '23514';
  end if;

  -- the consents that are a condition of asking
  if not coalesce((c -> 'terms' ->> 'accepted')::boolean, false) or nullif(c -> 'terms' ->> 'version', '') is null
     or nullif(c -> 'terms' ->> 'text', '') is null then
    raise exception 'The Terms of Use must be accepted, with the version and wording shown' using errcode = '22023';
  end if;
  if not coalesce((c -> 'privacy' ->> 'accepted')::boolean, false) or nullif(c -> 'privacy' ->> 'version', '') is null
     or nullif(c -> 'privacy' ->> 'text', '') is null then
    raise exception 'The Privacy Policy must be accepted, with the version and wording shown' using errcode = '22023';
  end if;
  if coalesce((c -> 'marketing' ->> 'opted_in')::boolean, false)
     and (nullif(c -> 'marketing' ->> 'version', '') is null or nullif(c -> 'marketing' ->> 'text', '') is null) then
    raise exception 'A marketing opt-in is recorded with the version and wording shown' using errcode = '22023';
  end if;

  -- who is asking (read only, so that a limit below can refuse with nothing written)
  if p_user is not null then
    select * into u from users where id = p_user;
    if u.id is null then raise exception 'Unknown user' using errcode = '22023'; end if;
  else
    if v_email = '' or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
      raise exception 'A valid email address is needed' using errcode = '22023';
    end if;
    select * into u from users where lower(email) = v_email;
  end if;
  if u.id is not null then
    if u.status not in ('active', 'invited') then
      raise exception 'We could not take this request online. Please contact us.' using errcode = '23514';
    end if;
    select * into rn from renters where user_id = u.id;
    if rn.id is not null then
      select * into dr from drivers where renter_id = rn.id and is_account_holder;
      if (select count(*) from bookings o where o.renter_id = rn.id and o.status in ('requested', 'offered', 'pending_payment'))
         >= v_set.booking_open_request_limit then
        return jsonb_build_object('ok', false, 'error', 'too_many_open_requests',
          'message', format('You already have %s requests open. Finish or withdraw one first, or call us.', v_set.booking_open_request_limit));
      end if;
    end if;
  end if;

  -- the renter as a driver: what we hold wins over what an unsigned-in visitor typed
  v_name := coalesce(dr.full_name, rn.legal_name, v_name, u.full_name);
  if dr.id is not null and v_dob is not null and v_dob <> dr.date_of_birth and p_user is null then v_differ := true; end if;
  v_dob := coalesce(dr.date_of_birth, rn.date_of_birth, v_dob);
  v_mobile := coalesce(v_mobile, rn.mobile, u.phone);
  if v_name is null or v_dob is null then
    raise exception 'The renter''s full legal name and date of birth are needed' using errcode = '22023';
  end if;
  if v_mobile is null then
    raise exception 'A mobile number is needed' using errcode = '22023';
  end if;
  v_on := app.local_date(v_pickup);
  v_age := app.age_on(v_dob, v_on);
  if v_age < v_set.min_renter_age then
    raise exception 'Every driver must be % or older at pickup', v_set.min_renter_age using errcode = '23514';
  end if;
  v_band := app.age_band(v_age);
  if v_band = '18_to_20' and not v.allows_18_to_20 then
    raise exception 'This car is for drivers % and over', v_set.standard_min_age using errcode = '23514';
  end if;
  -- the licence: a class we accept, or one from elsewhere for staff to confirm. What is on file wins.
  v_class := coalesce(upper(dr.licence_class), v_class);
  v_issuer := coalesce(dr.licence_issuer, v_issuer);
  if v_class is null then
    raise exception 'The licence class is needed' using errcode = '22023';
  elsif not v_class = any (select upper(x) from unnest(v_set.accepted_licence_classes) x) then
    if v_class = 'OTHER' and v_set.other_licence_for_review and v_issuer is not null then
      v_review := true;
    else
      raise exception 'A class % licence is needed, or an equivalent from another province or country with its issuer',
        array_to_string(v_set.accepted_licence_classes, ' or ') using errcode = '23514';
    end if;
  end if;

  -- additional drivers
  if jsonb_array_length(v_adds) > v_set.max_additional_drivers then
    raise exception 'A booking may name up to % additional drivers', v_set.max_additional_drivers using errcode = '22023';
  end if;
  v_names := array[lower(regexp_replace(v_name, '\s+', ' ', 'g')) || '|' || v_dob];
  for a in select value from jsonb_array_elements(v_adds) loop
    v_a_name := nullif(btrim(coalesce(a ->> 'full_name', '')), '');
    v_a_dob := (a ->> 'date_of_birth')::date;
    v_a_email := lower(nullif(btrim(coalesce(a ->> 'email', '')), ''));
    v_a_class := upper(nullif(btrim(coalesce(a ->> 'licence_class', '')), ''));
    if v_a_name is null or v_a_dob is null or v_a_email is null then
      raise exception 'Each additional driver needs a full name, a date of birth and an email address' using errcode = '22023';
    end if;
    v_a_age := app.age_on(v_a_dob, v_on);
    if v_a_age < v_set.min_renter_age then
      raise exception 'Every driver must be % or older at pickup', v_set.min_renter_age using errcode = '23514';
    end if;
    if app.age_band(v_a_age) = '18_to_20' and not v.allows_18_to_20 then
      raise exception 'This car is for drivers % and over', v_set.standard_min_age using errcode = '23514';
    end if;
    if v_a_class is not null and not v_a_class = any (select upper(x) from unnest(v_set.accepted_licence_classes) x) then
      if v_a_class = 'OTHER' and v_set.other_licence_for_review and nullif(btrim(coalesce(a ->> 'licence_issuer', '')), '') is not null then
        v_review := true;
      else
        raise exception 'A class % licence is needed, or an equivalent from another province or country with its issuer',
          array_to_string(v_set.accepted_licence_classes, ' or ') using errcode = '23514';
      end if;
    end if;
    if (lower(regexp_replace(v_a_name, '\s+', ' ', 'g')) || '|' || v_a_dob) = any (v_names) then
      raise exception 'The same driver is named twice' using errcode = '22023';
    end if;
    v_names := v_names || (lower(regexp_replace(v_a_name, '\s+', ' ', 'g')) || '|' || v_a_dob);
  end loop;

  -- ---- from here on the request is written
  if u.id is null then
    v_uid := coalesce((r ->> 'user_id')::uuid, gen_random_uuid());
    insert into users (id, email, phone, full_name) values (v_uid, v_email, v_mobile, v_name) returning * into u;
    v_new_account := true;
  end if;
  insert into user_roles (user_id, role) values (u.id, 'renter') on conflict do nothing;
  if rn.id is null then
    insert into renters (user_id, legal_name, date_of_birth, mobile, email)
    values (u.id, v_name, v_dob, v_mobile, u.email) returning * into rn;
  else
    update renters set mobile = case when p_user is not null then v_mobile else coalesce(mobile, v_mobile) end,
                       date_of_birth = coalesce(date_of_birth, v_dob), email = coalesce(email, u.email)
     where id = rn.id returning * into rn;
  end if;
  if dr.id is null then
    insert into drivers (renter_id, is_account_holder, user_id, full_name, date_of_birth, licence_class, licence_issuer, mobile, email)
    values (rn.id, true, u.id, v_name, v_dob, v_class, v_issuer, v_mobile, u.email) returning * into dr;
  elsif dr.licence_class is null then
    update drivers set licence_class = v_class, licence_issuer = coalesce(licence_issuer, v_issuer) where id = dr.id returning * into dr;
  end if;

  v_conflict := not app.vehicle_is_available(v_vehicle, v_pickup, v_return);
  v_booking := app.request_booking(rn.id, v_vehicle, v_pickup, v_return, v_type::booking_type, v_note, 'web', u.id,
                                   nullif(btrim(coalesce(p_request ->> 'referred_by_code', '')), ''), null,
                                   v_pickup_method, v_return_method,
                                   nullif(btrim(coalesce(p_request ->> 'pickup_place', '')), ''),
                                   nullif(btrim(coalesce(p_request ->> 'return_place', '')), ''));

  -- drivers on the booking, as they will be printed in the agreement's summary
  insert into booking_drivers (booking_id, driver_id, role, full_name, date_of_birth, licence_number, licence_class, licence_issuer,
                               licence_expiry, age_at_pickup, age_band)
  values (v_booking, dr.id, 'renter', dr.full_name, dr.date_of_birth, dr.licence_number, dr.licence_class, dr.licence_issuer,
          dr.licence_expiry, v_age, v_band);
  v_drivers_kept := jsonb_build_array(jsonb_build_object('role', 'renter', 'full_name', dr.full_name, 'age_band', v_band));
  for a in select value from jsonb_array_elements(v_adds) loop
    v_a_name := btrim(a ->> 'full_name');
    v_a_dob := (a ->> 'date_of_birth')::date;
    v_a_email := lower(btrim(a ->> 'email'));
    v_a_class := upper(nullif(btrim(coalesce(a ->> 'licence_class', '')), ''));
    v_a_issuer := nullif(btrim(coalesce(a ->> 'licence_issuer', '')), '');
    v_a_age := app.age_on(v_a_dob, v_on);
    select d.id into v_driver from drivers d
     where d.renter_id = rn.id and not d.is_account_holder and d.date_of_birth = v_a_dob
       and lower(regexp_replace(d.full_name, '\s+', ' ', 'g')) = lower(regexp_replace(v_a_name, '\s+', ' ', 'g'))
     order by d.created_at limit 1;
    if v_driver is null then
      insert into drivers (renter_id, full_name, date_of_birth, licence_class, licence_issuer, email)
      values (rn.id, v_a_name, v_a_dob, v_a_class, v_a_issuer, v_a_email) returning id into v_driver;
    else
      update drivers set email = coalesce(email, v_a_email), licence_class = coalesce(licence_class, v_a_class),
                         licence_issuer = coalesce(licence_issuer, v_a_issuer) where id = v_driver;
    end if;
    insert into booking_drivers (booking_id, driver_id, role, full_name, date_of_birth, licence_number, licence_class, licence_issuer,
                                 licence_expiry, age_at_pickup, age_band)
    select v_booking, d.id, 'additional', d.full_name, d.date_of_birth, d.licence_number, d.licence_class, d.licence_issuer,
           d.licence_expiry, v_a_age, app.age_band(v_a_age)
      from drivers d where d.id = v_driver;
    v_drivers_kept := v_drivers_kept || jsonb_build_object('role', 'additional', 'full_name', v_a_name, 'age_band', app.age_band(v_a_age));
  end loop;

  -- the fee terms of this booking, as they stand today: a later change to a default does not move this price
  insert into booking_fee_terms (booking_id, fee_type_code, amount_cents, cap_cents, percent_bps, source)
  select v_booking, x.code, t.amount_cents, t.cap_cents, t.percent_bps, t.source
    from unnest(array['young_driver_18_20', 'young_driver_21_25', 'additional_driver', 'winter_tire', 'baby_seat', 'coverage_sold']) x(code)
    cross join lateral public.effective_fee(x.code, v_vehicle, app.today()) t
  on conflict (booking_id, fee_type_code) do nothing;

  -- the request as sent. Dates of birth, licence details and other people's contact details are
  -- not copied here: they are on the driver records, which fewer staff may read.
  v_details := (q - 'details' - 'consents' - 'renter' - 'additional_drivers' - 'request_key')
    || coalesce(case when jsonb_typeof(q -> 'details') = 'object' then q -> 'details' end, '{}'::jsonb)
    || jsonb_build_object(
         'submitted_at', now(), 'drivers', v_drivers_kept,
         'extras', jsonb_build_object('winter_tire', coalesce((q -> 'extras' ->> 'winter_tire')::boolean, false), 'baby_seats', v_seats),
         'coverage_option', v_cover,
         'terms_version', c -> 'terms' ->> 'version', 'terms_accepted_at', now(),
         'privacy_version', c -> 'privacy' ->> 'version',
         'marketing_opt_in', coalesce((c -> 'marketing' ->> 'opted_in')::boolean, false),
         'conflict_at_submit', v_conflict, 'licence_needs_review', v_review,
         'details_differ_from_record', v_differ, 'new_account', v_new_account);
  update bookings set request_key = v_key, request_details = v_details, coverage_option = v_cover where id = v_booking;
  perform app.reprice_booking(v_booking);

  -- a promo code that cannot be used does not stop the request: the reason is kept and returned
  if nullif(btrim(coalesce(p_request ->> 'promo_code', '')), '') is not null then
    v_promo_problem := app.promo_code_problem(p_request ->> 'promo_code', rn.id, v_booking);
    if v_promo_problem is null then
      perform app.apply_promo_code(v_booking, p_request ->> 'promo_code', u.id);
    else
      update bookings set request_details = request_details || jsonb_build_object('promo_problem', v_promo_problem) where id = v_booking;
    end if;
  end if;

  -- consents: each its own row, with the wording shown, its version, when, and from where
  insert into consents (user_id, driver_id, booking_id, consent_code, text_version, text_shown, ip_address, user_agent)
  values (u.id, dr.id, v_booking, 'terms_of_use', c -> 'terms' ->> 'version', c -> 'terms' ->> 'text', p_ip, p_user_agent),
         (u.id, dr.id, v_booking, 'privacy_policy', c -> 'privacy' ->> 'version', c -> 'privacy' ->> 'text', p_ip, p_user_agent);
  if coalesce((c -> 'marketing' ->> 'opted_in')::boolean, false) then
    insert into consents (user_id, driver_id, booking_id, consent_code, text_version, text_shown, ip_address, user_agent)
    values (u.id, dr.id, v_booking, 'marketing', c -> 'marketing' ->> 'version', c -> 'marketing' ->> 'text', p_ip, p_user_agent);
    update users set marketing_opt_in = true, marketing_opt_in_at = coalesce(marketing_opt_in_at, now()), marketing_unsubscribed_at = null
     where id = u.id and not marketing_opt_in;
  end if;

  if rn.is_blocked then
    insert into tasks (queue, task_type, title, detail, procedure_no, priority, booking_id, vehicle_id, renter_id)
    select 'admin', 'blocked_renter_request', format('Request %s is from a blocked customer', o.booking_number),
           'The customer was shown the normal confirmation. Decide whether to decline the request.', 1, 'high', o.id, o.vehicle_id, o.renter_id
      from bookings o where o.id = v_booking;
  end if;

  select * into b from bookings where id = v_booking;
  return jsonb_build_object('ok', true, 'created', true, 'booking_id', b.id, 'booking_number', b.booking_number, 'status', b.status,
    'renter_id', rn.id, 'user_id', u.id, 'new_account', v_new_account, 'conflict_at_submit', v_conflict,
    'licence_needs_review', v_review, 'promo_problem', v_promo_problem,
    'total_due_at_booking_cents', b.total_due_at_booking_cents, 'deposit_cents', b.deposit_cents);
end $$;

-- ================================================================ signing built into the platform
-- Void every agreement on a booking that is still open or signed but not completed, with the
-- reason. A completed agreement is never voided. Returns how many were voided.
create or replace function app.void_rental_agreements(p_booking uuid, p_reason text) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  a record;
  n integer := 0;
begin
  for a in select id, signature_request_id, agreement_number, offer_version, status from rental_agreements
            where booking_id = p_booking and status in ('open', 'signed') for update
  loop
    update rental_agreements set status = 'voided', voided_at = now(), void_reason = coalesce(nullif(btrim(p_reason), ''), 'voided') where id = a.id;
    update signature_requests set status = 'voided' where id = a.signature_request_id;
    perform app.log_booking_event(p_booking, 'agreement_voided', null, null, a.offer_version, p_reason, null, 'system',
      jsonb_build_object('agreement_id', a.id, 'agreement_number', a.agreement_number, 'was', a.status));
    n := n + 1;
  end loop;
  return n;
end $$;

-- Open the rental agreement of a booking for signature. The server renders the document from
-- the booking and passes the exact version of the agreement text, where the file is, and the
-- SHA-256 of the rendered file. One signer row is made for the renter, one for every additional
-- driver, and one for CarmaCars (the staff member who sent the approved offer, whose name the
-- countersignature will carry).
--   * Only for a booking whose current offer is approved (or an Owner Booking sent to signing).
--   * Asking again with the same version, text version and hash returns the agreement already open.
--   * Anything else replaces it: the earlier agreement is voided, signatures on it included.
create or replace function app.open_rental_agreement(p_booking uuid, p_by uuid, p_template_version text, p_document_sha256 text,
                                                     p_storage_path text, p_storage_bucket text default 'agreements')
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  a rental_agreements;
  rn renters;
  v_set program_settings := app.settings();
  v_owner boolean;
  v_version integer;
  v_sha text := lower(btrim(coalesce(p_document_sha256, '')));
  v_reissue boolean;
  v_number text;
  v_cs uuid;
  v_cs_name text;
  v_doc uuid;
  v_req uuid;
  v_id uuid := gen_random_uuid();
  s record;
begin
  select * into b from bookings where id = p_booking for update;
  if b.id is null then raise exception 'Booking % not found', p_booking; end if;
  if p_by is null or not (app.is_booking_renter(p_booking, p_by) or app.user_is_staff(p_by)) then
    raise exception 'Only the renter of this booking, or staff, opens its agreement' using errcode = '42501';
  end if;
  v_owner := b.booking_type = 'owner';
  if b.status <> 'pending_payment' then
    raise exception 'Booking % is %: the agreement is opened once the offer is approved', b.booking_number, b.status using errcode = '23514';
  end if;
  if not v_owner and (b.offer_approved_version is null or b.offer_approved_version is distinct from b.current_offer_version) then
    raise exception 'Booking % has no approved offer to sign for', b.booking_number using errcode = '23514';
  end if;
  if nullif(btrim(coalesce(p_template_version, '')), '') is null or nullif(btrim(coalesce(p_storage_path, '')), '') is null
     or v_sha !~ '^[0-9a-f]{64}$' then
    raise exception 'An agreement needs its text version, its file and the SHA-256 of the rendered document' using errcode = '22023';
  end if;
  v_version := case when v_owner then null else b.offer_approved_version end;

  select * into a from rental_agreements where booking_id = p_booking and status in ('open', 'signed', 'completed');
  if a.id is not null then
    if a.status = 'completed' then
      raise exception 'The agreement of booking % is already completed', b.booking_number using errcode = '23514';
    end if;
    if a.offer_version is not distinct from v_version and a.document_sha256 = v_sha and a.template_version = p_template_version then
      return a.id;
    end if;
    perform app.void_rental_agreements(p_booking, 'A new version of the agreement was issued');
  end if;
  v_reissue := exists (select 1 from rental_agreements x where x.booking_id = p_booking);

  select * into rn from renters where id = b.renter_id;
  v_number := coalesce(b.agreement_number, 'RA-' || nextval('rental_agreement_number_seq'));
  -- who signs for CarmaCars: the staff member who sent the approved offer
  if v_owner then
    v_cs := case when app.user_is_staff(p_by) then p_by when app.user_is_staff(b.created_by) then b.created_by end;
  else
    select o.sent_by into v_cs from booking_offers o
     where o.booking_id = p_booking and o.version <= b.offer_approved_version and o.sent_by is not null
     order by o.version desc limit 1;
  end if;
  v_cs_name := coalesce((select u.full_name from users u where u.id = v_cs), v_set.company_trade_name);

  insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256, template_version, retention, uploaded_by, renter_id, booking_id)
  values ('rental_agreement', format('Rental agreement %s', v_number), p_storage_bucket, p_storage_path, 'application/pdf', v_sha,
          p_template_version, 'records_7y', p_by, b.renter_id, p_booking)
  returning id into v_doc;
  insert into signature_requests (document_id, provider, provider_envelope, status, sent_at, created_by)
  values (v_doc, 'builtin', v_id::text, 'sent', now(), p_by)
  returning id into v_req;
  insert into rental_agreements (id, booking_id, offer_version, agreement_number, template_version, document_id, document_sha256,
                                 signature_request_id, countersigner_user_id, countersigner_name, opened_by)
  values (v_id, p_booking, v_version, v_number, p_template_version, v_doc, v_sha, v_req, v_cs, v_cs_name, p_by);

  -- the renter
  insert into rental_agreement_signers (agreement_id, signer_role, booking_driver_id, driver_id, user_id, signer_name, signer_email, required_before_payment)
  select v_id, 'renter', d.id, d.driver_id, rn.user_id, coalesce(d.full_name, rn.legal_name),
         coalesce(rn.email, (select u.email from users u where u.id = rn.user_id)), true
    from (select 1) one
    left join booking_drivers d on d.booking_id = p_booking and d.role = 'renter';
  -- every additional driver accepts the same document, before the car is handed over
  insert into rental_agreement_signers (agreement_id, signer_role, booking_driver_id, driver_id, user_id, signer_name, signer_email)
  select v_id, 'additional_driver', d.id, d.driver_id, dv.user_id, d.full_name, dv.email
    from booking_drivers d join drivers dv on dv.id = d.driver_id
   where d.booking_id = p_booking and d.role = 'additional';
  -- CarmaCars
  insert into rental_agreement_signers (agreement_id, signer_role, user_id, signer_name, signer_email)
  values (v_id, 'carmacars', v_cs, v_cs_name, v_set.company_email);

  update bookings set agreement_number = v_number, agreement_document_id = v_doc, signature_request_id = v_req where id = p_booking;
  perform app.log_booking_event(p_booking, 'agreement_opened', b.status::text, b.status::text, v_version, null, p_by, null,
    jsonb_build_object('agreement_id', v_id, 'agreement_number', v_number, 'template_version', p_template_version,
                       'document_sha256', v_sha, 'reissued', v_reissue));

  -- "your agreement is ready": to each additional driver, and to the renter when the agreement
  -- was reissued or opened for them by staff (a renter in the middle of checkout needs no email)
  for s in select g.id, g.signer_role, g.signer_name, g.signer_email, g.user_id from rental_agreement_signers g
            where g.agreement_id = v_id
              and (g.signer_role = 'additional_driver'
                   or (g.signer_role = 'renter' and (v_reissue or not app.is_booking_renter(p_booking, p_by))))
  loop
    perform app.emit_event('renter_agreement_ready', 'rental_agreement', v_id,
      jsonb_build_object('booking_id', p_booking, 'booking_number', b.booking_number, 'agreement_number', v_number, 'signer_id', s.id,
                         'signer_role', s.signer_role, 'signer_name', s.signer_name, 'signer_email', s.signer_email,
                         'signer_user_id', s.user_id, 'reissued', v_reissue),
      'renter_agreement_ready:' || v_id || ':' || s.id);
  end loop;
  return v_id;
end $$;

-- One signer signs. A signature is a new signature_records row and is never changed afterwards.
--   p_request            the signature request of the agreement
--   p_signer             the signer's row in rental_agreement_signers
--   p_typed_name         the name typed (required when nothing was drawn; it must be the signer's name)
--   p_drawn_signature    where the drawn signature is stored (private storage), when one was drawn
--   p_consent_text       the statement the signer agreed to, word for word
--   p_document_sha256    the hash of the document on the signer's screen; refused when it is not
--                        the agreement's (the document was reissued)
--   p_consents           the booking consents ticked at signing: [{code, version, text}]
-- The renter signs for the offer version that is approved now, and only that one.
create or replace function app.record_signature(p_request uuid, p_signer uuid, p_typed_name text, p_drawn_signature text,
                                                p_ip inet, p_user_agent text, p_consent_text text,
                                                p_document_sha256 text default null, p_consents jsonb default null)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  a rental_agreements;
  g rental_agreement_signers;
  b bookings;
  v_typed text := nullif(btrim(coalesce(p_typed_name, '')), '');
  v_drawn text := nullif(btrim(coalesce(p_drawn_signature, '')), '');
  v_rec uuid;
  k jsonb;
begin
  select * into a from rental_agreements where signature_request_id = p_request for update;
  if a.id is null then raise exception 'No rental agreement is open under this signature request' using errcode = '22023'; end if;
  select * into g from rental_agreement_signers where id = p_signer and agreement_id = a.id for update;
  if g.id is null then raise exception 'This signer is not on this agreement' using errcode = '42501'; end if;
  select * into b from bookings where id = a.booking_id for update;
  if g.signer_role = 'carmacars' then
    raise exception 'The countersignature for CarmaCars is applied when the booking is confirmed' using errcode = '42501';
  end if;
  if a.status = 'voided' then
    raise exception 'This agreement was replaced (%): sign the current one', a.void_reason using errcode = '23514';
  end if;
  if g.signed_at is not null then
    raise exception '% has already signed this agreement', g.signer_name using errcode = '23514';
  end if;
  if g.signer_role = 'renter' then
    if a.status <> 'open' or b.status <> 'pending_payment' then
      raise exception 'This agreement is not open for the renter''s signature' using errcode = '23514';
    end if;
    if b.booking_type <> 'owner' and (b.offer_approved_version is null or a.offer_version is distinct from b.offer_approved_version) then
      raise exception 'This agreement is for an offer that is no longer the approved one: sign the current agreement' using errcode = '23514';
    end if;
  elsif b.status not in ('pending_payment', 'confirmed') then
    raise exception 'Booking % is %: there is nothing to accept', b.booking_number, b.status using errcode = '23514';
  end if;
  if p_document_sha256 is not null and lower(btrim(p_document_sha256)) <> a.document_sha256 then
    raise exception 'The document changed after it was opened: reload and sign the current version' using errcode = '23514';
  end if;
  if v_typed is null and v_drawn is null then
    raise exception 'Sign by drawing a signature or by typing your full legal name' using errcode = '22023';
  end if;
  if v_drawn is null and lower(regexp_replace(v_typed, '\s+', '', 'g')) <> lower(regexp_replace(g.signer_name, '\s+', '', 'g')) then
    raise exception 'The typed name must be the signer''s full legal name (%)', g.signer_name using errcode = '23514';
  end if;
  if nullif(btrim(coalesce(p_consent_text, '')), '') is null then
    raise exception 'The statement the signer agreed to is recorded with the signature' using errcode = '22023';
  end if;

  insert into signature_records (signature_request_id, signer_role, signer_user_id, signer_name, signer_email, status, signed_at, method,
                                 ip_address, user_agent, provider_signature, typed_name, consent_text, document_sha256)
  values (p_request, g.signer_role, g.user_id, g.signer_name, g.signer_email, 'signed', now(),
          case when v_drawn is not null then 'drawn' else 'typed' end, p_ip, p_user_agent, v_drawn, v_typed, p_consent_text, a.document_sha256)
  returning id into v_rec;
  update rental_agreement_signers set signature_record_id = v_rec, signed_at = now() where id = g.id;

  if jsonb_typeof(p_consents) = 'array' then
    for k in select value from jsonb_array_elements(p_consents) loop
      insert into consents (user_id, driver_id, booking_id, consent_code, text_version, text_shown, ip_address, user_agent)
      values (g.user_id, g.driver_id, a.booking_id, k ->> 'code', k ->> 'version', k ->> 'text', p_ip, p_user_agent);
    end loop;
  end if;

  if g.signer_role = 'renter' then
    update rental_agreements set status = 'signed', renter_signed_at = now() where id = a.id;
    update signature_requests set status = 'partially_signed' where id = p_request;
  else
    update booking_drivers set signature_record_id = v_rec, accepted_at = now() where id = g.booking_driver_id;
  end if;
  perform app.log_booking_event(a.booking_id, 'agreement_signed', b.status::text, b.status::text, a.offer_version, null, g.user_id,
    case when g.signer_role = 'renter' then 'renter' else 'system' end,
    jsonb_build_object('agreement_id', a.id, 'signer_id', g.id, 'signer_role', g.signer_role, 'signer_name', g.signer_name,
                       'signature_record_id', v_rec));
  return v_rec;
end $$;

-- Complete the signature request of a rental agreement: the countersignature of CarmaCars is
-- written as its own signature record, in the name of the staff member who sent the offer, and
-- the request and the agreement are marked completed. Called by the confirmation functions
-- below, in the transaction that confirms the booking.
--   * The renter (and anyone else who must sign before payment) has signed.
--   * The agreement is for the offer version that is approved now.
--   * When the renter owes something at booking, p_payment is the succeeded payment of exactly that amount.
-- The signed copy (rendered by the server once every signature is on it) may be passed here or
-- attached afterwards with app.attach_signed_agreement().
create or replace function app.complete_signature_request(p_request uuid, p_payment uuid default null,
                                                          p_signed_storage_path text default null, p_signed_sha256 text default null)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  a rental_agreements;
  b bookings;
  v_set program_settings := app.settings();
  v_rec uuid;
begin
  select * into a from rental_agreements where signature_request_id = p_request for update;
  if a.id is null then raise exception 'No rental agreement is open under this signature request' using errcode = '22023'; end if;
  if a.status = 'completed' then
    if p_signed_storage_path is not null then
      perform app.attach_signed_agreement(p_request, p_signed_storage_path, p_signed_sha256);
    end if;
    return a.id;
  end if;
  select * into b from bookings where id = a.booking_id for update;
  if a.status <> 'signed' then
    raise exception 'The agreement of booking % is %: it is completed once the renter has signed', b.booking_number, a.status using errcode = '23514';
  end if;
  if exists (select 1 from rental_agreement_signers g where g.agreement_id = a.id and g.required_before_payment and g.signed_at is null) then
    raise exception 'The agreement of booking % is not fully signed', b.booking_number using errcode = '23514';
  end if;
  if b.status <> 'pending_payment'
     or (b.booking_type <> 'owner' and (b.offer_approved_version is null or a.offer_version is distinct from b.offer_approved_version)) then
    raise exception 'The agreement of booking % is not for its approved offer', b.booking_number using errcode = '23514';
  end if;
  if b.booking_type <> 'owner' and b.renter_due_at_booking_cents > 0 and not exists (
       select 1 from payments p where p.id = p_payment and p.booking_id = b.id and p.purpose = 'booking_total' and p.kind = 'charge'
          and p.status = 'succeeded' and p.amount_cents = b.renter_due_at_booking_cents) then
    raise exception 'CarmaCars countersigns once the amount due at booking is paid' using errcode = '23514';
  end if;

  insert into signature_records (signature_request_id, signer_role, signer_user_id, signer_name, signer_title, signer_email, status, signed_at,
                                 method, typed_name, consent_text, document_sha256)
  values (p_request, 'carmacars', a.countersigner_user_id, a.countersigner_name, 'for ' || v_set.company_trade_name, v_set.company_email,
          'signed', now(), 'automatic', a.countersigner_name,
          format('Countersigned for %s automatically when the booking was confirmed, in the name of the staff member who sent the offer.',
                 v_set.company_trade_name), a.document_sha256)
  returning id into v_rec;
  update rental_agreement_signers set signature_record_id = v_rec, signed_at = now() where agreement_id = a.id and signer_role = 'carmacars';
  update signature_requests set status = 'completed', completed_at = now() where id = p_request;
  update rental_agreements set status = 'completed', completed_at = now() where id = a.id;
  perform app.log_booking_event(a.booking_id, 'agreement_completed', b.status::text, b.status::text, a.offer_version, null,
    a.countersigner_user_id, 'system',
    jsonb_build_object('agreement_id', a.id, 'agreement_number', a.agreement_number, 'countersigned_by', a.countersigner_name,
                       'signature_record_id', v_rec));
  if p_signed_storage_path is not null then
    perform app.attach_signed_agreement(p_request, p_signed_storage_path, p_signed_sha256);
  end if;
  perform app.emit_event('renter_agreement_signed', 'rental_agreement', a.id,
    jsonb_build_object('booking_id', a.booking_id, 'booking_number', b.booking_number, 'agreement_number', a.agreement_number,
                       'signature_request_id', p_request, 'countersigned_by', a.countersigner_name,
                       'signers', (select jsonb_agg(jsonb_build_object('signer_role', g.signer_role, 'signer_name', g.signer_name,
                                                                       'signer_email', g.signer_email, 'signed_at', g.signed_at) order by g.created_at, g.id)
                                     from rental_agreement_signers g where g.agreement_id = a.id and g.signed_at is not null)),
    'renter_agreement_signed:' || a.id || ':completed');
  return a.id;
end $$;

-- The signed copy: the document with every signature on it and its signature record page,
-- rendered by the server. Stored once; a signed file is never replaced.
create or replace function app.attach_signed_agreement(p_request uuid, p_storage_path text, p_sha256 text,
                                                       p_storage_bucket text default 'agreements')
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  a rental_agreements;
  s signature_requests;
  v_doc uuid;
begin
  select * into a from rental_agreements where signature_request_id = p_request;
  select * into s from signature_requests where id = p_request for update;
  if a.id is null or s.id is null then raise exception 'No rental agreement is open under this signature request' using errcode = '22023'; end if;
  if s.status <> 'completed' then
    raise exception 'The signed copy is stored once the agreement is completed' using errcode = '23514';
  end if;
  if s.signed_document_id is not null then
    raise exception 'The signed copy of agreement % is already stored and is never replaced', a.agreement_number using errcode = '23514';
  end if;
  if nullif(btrim(coalesce(p_storage_path, '')), '') is null or lower(btrim(coalesce(p_sha256, ''))) !~ '^[0-9a-f]{64}$' then
    raise exception 'The signed copy needs its file and its SHA-256' using errcode = '22023';
  end if;
  insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256, template_version, retention, renter_id, booking_id)
  select 'rental_agreement', format('Rental agreement %s, signed', a.agreement_number), p_storage_bucket, p_storage_path, 'application/pdf',
         lower(btrim(p_sha256)), a.template_version, 'records_7y', b.renter_id, b.id
    from bookings b where b.id = a.booking_id
  returning id into v_doc;
  update signature_requests set signed_document_id = v_doc where id = p_request;
  update bookings set agreement_document_id = v_doc where id = a.booking_id;
  return v_doc;
end $$;

-- ================================================================ payment
-- A payment processor event is handled once. Returns {first, id, processed, result}: "first"
-- when this call recorded the event; otherwise whether it was already handled, and its result.
create or replace function app.webhook_event_claim(p_provider text, p_event_id text, p_event_type text default null,
                                                   p_booking uuid default null, p_summary jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  w webhook_events;
  v_id uuid;
begin
  if nullif(btrim(coalesce(p_provider, '')), '') is null or nullif(btrim(coalesce(p_event_id, '')), '') is null then
    raise exception 'A processor event needs its provider and its id' using errcode = '22023';
  end if;
  insert into webhook_events (provider, event_id, event_type, booking_id, summary)
  values (p_provider, p_event_id, p_event_type, p_booking, coalesce(p_summary, '{}'::jsonb))
  on conflict (provider, event_id) do nothing
  returning id into v_id;
  if v_id is not null then
    return jsonb_build_object('first', true, 'id', v_id, 'processed', false, 'result', null);
  end if;
  select * into w from webhook_events where provider = p_provider and event_id = p_event_id for update;
  return jsonb_build_object('first', false, 'id', w.id, 'processed', w.processed_at is not null, 'result', w.result);
end $$;

create or replace function app.webhook_event_finish(p_provider text, p_event_id text, p_result jsonb default null, p_error text default null)
returns void language sql security definer set search_path = public, app as $$
  update webhook_events
     set processed_at = case when p_error is null then now() else processed_at end, result = coalesce(p_result, result), error = p_error
   where provider = p_provider and event_id = p_event_id
$$;

-- The renter's card as their Card on File: found by the processor's id for it, or created.
-- Only what may be shown is kept in payment_methods; the processor's ids go to the admin-only table.
create or replace function app.save_card_on_file(p_renter uuid, p_card jsonb, p_processor jsonb) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_method text := nullif(p_processor ->> 'method_id', '');
  v_id uuid;
begin
  if v_method is not null then
    select pm.id into v_id from payment_methods pm join payment_method_secrets s on s.payment_method_id = pm.id
     where pm.renter_id = p_renter and s.processor_method_id = v_method and pm.status = 'active' limit 1;
    if v_id is not null then return v_id; end if;
  end if;
  if p_card is null or jsonb_typeof(p_card) <> 'object' then return null; end if;
  insert into payment_methods (renter_id, card_brand, card_last4, cardholder_name, exp_month, exp_year, is_credit)
  values (p_renter, p_card ->> 'brand', p_card ->> 'last4', p_card ->> 'cardholder_name',
          (p_card ->> 'exp_month')::smallint, (p_card ->> 'exp_year')::smallint, (p_card ->> 'is_credit')::boolean)
  returning id into v_id;
  insert into payment_method_secrets (payment_method_id, processor, processor_customer_id, processor_method_id, fingerprint)
  values (v_id, coalesce(nullif(p_processor ->> 'processor', ''), 'stripe'), p_processor ->> 'customer_id', v_method, p_processor ->> 'fingerprint');
  return v_id;
end $$;

-- A booking waiting for signature and payment goes back to staff because its car is no longer
-- free: the offer is withdrawn, the history says why, and customer service gets a task.
create or replace function app.push_back_booking(p_booking uuid, p_note text) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
begin
  select * into b from bookings where id = p_booking for update;
  if b.status not in ('offered', 'pending_payment') then return; end if;
  update booking_offers set status = 'withdrawn', responded_at = now(), response_note = p_note
   where booking_id = p_booking and status in ('sent', 'approved');
  update bookings set status = 'requested' where id = p_booking;
  perform app.log_booking_event(p_booking, 'pushed_back', b.status::text, 'requested', b.current_offer_version, p_note, null, 'system');
  insert into tasks (queue, task_type, title, detail, procedure_no, priority, booking_id, vehicle_id, renter_id)
  values ('cs', 'reoffer_booking', format('Re-offer booking %s: the car was taken', b.booking_number),
          p_note || ' The card was not charged. Offer another vehicle or other dates, or decline.', 1, 'urgent',
          p_booking, b.vehicle_id, b.renter_id);
end $$;

-- A confirmation that is refused: written to the booking's history, and returned to the server
-- as a result (never as an error), so the server knows to void the card authorization.
create or replace function app.refuse_confirmation(p_booking uuid, p_mode text, p_reason text, p_message text, p_extra jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public, app as $$
begin
  perform app.log_booking_event(p_booking, 'payment_refused', null, null, null, p_message, null, 'system',
    jsonb_build_object('reason', p_reason, 'mode', p_mode) || coalesce(p_extra, '{}'::jsonb));
  return jsonb_build_object('ok', false, 'booking_id', p_booking, 'reason', p_reason, 'message', p_message,
           'action', case when p_mode = 'payment' then 'void_authorization' else 'none' end) || coalesce(p_extra, '{}'::jsonb);
end $$;

-- The one place a booking is confirmed. Under a lock on the vehicle, so that two bookings for
-- the same car are decided one after the other, it checks again that:
--   * the booking is waiting for signature and payment, on its approved, current offer version;
--   * the agreement for that version is signed by everyone who must sign before payment;
--   * the amount is exactly what the renter owes at booking (p_mode 'payment'), or nothing is
--     owed by the renter (p_mode 'nothing_due': an insurer pays, or an Owner Booking);
--   * the car is open for bookings and still free for the dates.
-- Then, in the same transaction: the card is saved, the payment is recorded and tied to the
-- charge lines, CarmaCars countersigns, and the booking becomes confirmed (which sends every
-- competing offer on the car back to staff). If the car was taken in the meantime the booking
-- itself goes back to staff. Every refusal is returned, not raised.
create or replace function app.finalize_booking(p_booking uuid, p_mode text, p_processor jsonb, p_amount_cents bigint,
                                                p_offer_version integer, p_card jsonb, p_by uuid)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  a rental_agreements;
  v_vehicle uuid;
  v_owner boolean;
  v_due bigint;
  v_proc text := coalesce(nullif(p_processor ->> 'processor', ''), 'stripe');
  v_pp text := nullif(p_processor ->> 'payment_id', '');
  v_pay uuid;
  v_pm uuid;
  v_taken boolean := false;
  v_note text;
begin
  if p_mode not in ('payment', 'nothing_due') then
    raise exception 'Unknown confirmation mode %', p_mode using errcode = '22023';
  end if;
  select vehicle_id into v_vehicle from bookings where id = p_booking;
  if v_vehicle is null then raise exception 'Booking % not found', p_booking; end if;
  -- the lock on the vehicle: every confirmation on this car waits here for the one before it
  perform 1 from vehicles where id = v_vehicle for no key update;
  select * into b from bookings where id = p_booking for update;
  if b.vehicle_id <> v_vehicle then
    perform 1 from vehicles where id = b.vehicle_id for no key update;   -- moved to another car between the two reads
  end if;
  v_owner := b.booking_type = 'owner';
  v_due := b.renter_due_at_booking_cents;

  -- the same payment reported twice, or a second confirmation of an Owner or insurer booking
  if b.status in ('confirmed', 'on_rent', 'returned', 'closed') then
    if p_mode = 'payment' and v_pp is not null then
      select p.id into v_pay from payments p join payment_processor_details d on d.payment_id = p.id
       where p.booking_id = p_booking and p.purpose = 'booking_total' and p.status = 'succeeded'
         and d.processor = v_proc and d.processor_payment_id = v_pp;
    end if;
    if v_pay is not null or (p_mode = 'nothing_due' and v_due <= 0) then
      return jsonb_build_object('ok', true, 'already_confirmed', true, 'booking_id', p_booking, 'booking_number', b.booking_number,
                                'status', b.status, 'payment_id', v_pay, 'action', case when p_mode = 'payment' then 'capture' else 'none' end);
    end if;
    return app.refuse_confirmation(p_booking, p_mode, 'already_confirmed', format('Booking %s is already confirmed.', b.booking_number));
  end if;
  if b.status <> 'pending_payment' then
    return app.refuse_confirmation(p_booking, p_mode, 'not_awaiting_payment',
      format('Booking %s is %s, not waiting for signature and payment. The offer may have been withdrawn or the car confirmed for someone else.',
             b.booking_number, b.status), jsonb_build_object('status', b.status));
  end if;

  if p_mode = 'payment' then
    if v_pp is null then
      raise exception 'The processor''s payment id is needed' using errcode = '22023';
    end if;
    if v_owner or v_due <= 0 then
      return app.refuse_confirmation(p_booking, p_mode, 'nothing_to_pay', format('The renter owes nothing at booking on %s.', b.booking_number));
    end if;
    if p_amount_cents is distinct from v_due then
      return app.refuse_confirmation(p_booking, p_mode, 'amount_mismatch',
        format('The amount does not equal what the renter owes at booking on %s.', b.booking_number),
        jsonb_build_object('expected_cents', v_due, 'received_cents', p_amount_cents));
    end if;
  elsif not v_owner then
    if v_due > 0 then
      return app.refuse_confirmation(p_booking, p_mode, 'payment_required',
        format('The renter owes an amount at booking on %s: it is confirmed by its payment.', b.booking_number),
        jsonb_build_object('expected_cents', v_due));
    end if;
    if b.bill_to = 'renter' then
      return app.refuse_confirmation(p_booking, p_mode, 'nothing_due_but_billed_to_renter',
        format('Booking %s is billed to the renter with nothing due. A booking with no charge needs an Admin.', b.booking_number));
    end if;
  end if;

  if not v_owner and (b.offer_approved_version is null or b.offer_approved_version is distinct from b.current_offer_version
                      or p_offer_version is distinct from b.offer_approved_version
                      or not exists (select 1 from booking_offers o where o.booking_id = p_booking
                                        and o.version = b.offer_approved_version and o.status = 'approved')) then
    return app.refuse_confirmation(p_booking, p_mode, 'offer_changed',
      format('The offer on %s changed after it was approved. The renter approves and signs the current version first.', b.booking_number),
      jsonb_build_object('approved_version', b.offer_approved_version, 'paid_for_version', p_offer_version));
  end if;

  select * into a from rental_agreements where booking_id = p_booking and status in ('open', 'signed');
  if a.id is null or a.status <> 'signed' or a.signature_request_id is distinct from b.signature_request_id
     or a.offer_version is distinct from (case when v_owner then null else b.offer_approved_version end)
     or exists (select 1 from rental_agreement_signers g where g.agreement_id = a.id and g.required_before_payment and g.signed_at is null) then
    return app.refuse_confirmation(p_booking, p_mode, 'agreement_not_signed',
      format('The rental agreement for the approved offer on %s is not signed.', b.booking_number));
  end if;

  if not v_owner then
    if not coalesce(app.vehicle_bookable(b.vehicle_id), false) then
      return app.refuse_confirmation(p_booking, p_mode, 'vehicle_not_bookable',
        format('The vehicle of %s is not open for bookings at the moment.', b.booking_number));
    end if;
    if p_card is not null and (p_card ->> 'is_credit') = 'false' then
      return app.refuse_confirmation(p_booking, p_mode, 'card_not_credit', 'The Card on File must be a credit card in the renter''s name.');
    end if;
    if p_card is null and b.card_on_file_id is null
       and not exists (select 1 from payment_methods pm where pm.renter_id = b.renter_id and pm.status = 'active') then
      return app.refuse_confirmation(p_booking, p_mode, 'no_card', 'No saved card, no confirmed booking.');
    end if;
  end if;

  if b.blocks_calendar and not app.vehicle_is_available(b.vehicle_id, b.pickup_at, b.return_at, b.id) then
    v_taken := true;
  else
    begin
      if not v_owner then
        v_pm := coalesce(app.save_card_on_file(b.renter_id, p_card, p_processor), b.card_on_file_id,
                         (select pm.id from payment_methods pm where pm.renter_id = b.renter_id and pm.status = 'active'
                           order by pm.created_at desc, pm.id limit 1));
        update bookings set card_on_file_id = v_pm where id = p_booking;
      end if;
      if p_mode = 'payment' then
        -- the row the server wrote when it created the payment at the processor, if it did
        select p.id into v_pay from payments p join payment_processor_details d on d.payment_id = p.id
         where p.booking_id = p_booking and p.purpose = 'booking_total' and d.processor = v_proc and d.processor_payment_id = v_pp
           and p.status in ('pending', 'requires_action', 'authorized')
         order by p.created_at limit 1;
        if v_pay is null then
          insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, payment_method_id, card_brand, card_last4,
                                processed_at, created_by)
          values (p_booking, b.renter_id, 'booking_total', 'charge', 'card', p_amount_cents, 'succeeded', v_pm,
                  (select pm.card_brand from payment_methods pm where pm.id = v_pm), (select pm.card_last4 from payment_methods pm where pm.id = v_pm),
                  now(), p_by)
          returning id into v_pay;
          insert into payment_processor_details (payment_id, processor, processor_payment_id, processor_charge_id, receipt_url)
          values (v_pay, v_proc, v_pp, p_processor ->> 'charge_id', p_processor ->> 'receipt_url');
        else
          update payments set status = 'succeeded', amount_cents = p_amount_cents, payment_method_id = v_pm, processed_at = now(),
                 card_brand = (select pm.card_brand from payment_methods pm where pm.id = v_pm),
                 card_last4 = (select pm.card_last4 from payment_methods pm where pm.id = v_pm)
           where id = v_pay;
          update payment_processor_details
             set processor_charge_id = coalesce(p_processor ->> 'charge_id', processor_charge_id),
                 receipt_url = coalesce(p_processor ->> 'receipt_url', receipt_url)
           where payment_id = v_pay;
        end if;
        -- what this payment paid for. On a booking billed wholly to an insurer the rental lines
        -- wait for the insurer's payment (app.record_insurer_payment ties them).
        update booking_line_items
           set payment_id = v_pay
         where booking_id = p_booking and stage = 'booking' and charged_to_renter and voided_at is null and payment_id is null
           and not (b.bill_to = 'insurer' and revenue_class = 'owner_revenue');
      end if;
      perform app.complete_signature_request(a.signature_request_id, v_pay);
      update bookings set status = 'confirmed' where id = p_booking;
    exception when exclusion_violation then
      -- another booking took the car between the check above and the confirmation
      v_taken := true;
    end;
  end if;

  if v_taken then
    v_note := format('The car was confirmed for another booking, or blocked, before booking %s could be confirmed.', b.booking_number);
    perform app.push_back_booking(p_booking, v_note);
    return app.refuse_confirmation(p_booking, p_mode, 'vehicle_taken', v_note);
  end if;

  perform app.log_booking_event(p_booking, 'confirmed', 'pending_payment', 'confirmed', b.offer_approved_version, null, p_by,
    case when p_by is null then 'system' end,
    jsonb_build_object('mode', p_mode, 'payment_id', v_pay, 'amount_cents', case when p_mode = 'payment' then p_amount_cents else 0 end,
                       'agreement_id', a.id));
  return jsonb_build_object('ok', true, 'booking_id', p_booking, 'booking_number', b.booking_number, 'status', 'confirmed',
                            'payment_id', v_pay, 'amount_cents', case when p_mode = 'payment' then p_amount_cents else 0 end,
                            'card_on_file_id', v_pm, 'agreement_id', a.id,
                            'action', case when p_mode = 'payment' then 'capture' else 'none' end);
end $$;

-- The payment of a booking, reported by the server once the card is AUTHORIZED (not yet
-- captured). The server captures only when this returns ok with action 'capture'; on any other
-- result it voids the authorization, so a renter who lost the race for a car is never charged.
--   p_processor   {processor, payment_id, charge_id, customer_id, method_id, fingerprint, receipt_url}
--   p_amount_cents the amount authorized
--   p_offer_version the offer version the renter paid for
--   p_card        {brand, last4, cardholder_name, exp_month, exp_year, is_credit}
--   p_event_id    the processor's id for the event: the same event is handled once
create or replace function app.record_booking_payment(p_booking uuid, p_processor jsonb, p_amount_cents bigint, p_offer_version integer,
                                                      p_card jsonb default null, p_event_id text default null, p_by uuid default null)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  v_proc text := coalesce(nullif(p_processor ->> 'processor', ''), 'stripe');
  v_evt jsonb;
  v_result jsonb;
begin
  if p_event_id is not null then
    v_evt := app.webhook_event_claim(v_proc, p_event_id, 'booking_payment', p_booking,
               jsonb_build_object('payment_id', p_processor ->> 'payment_id', 'amount_cents', p_amount_cents, 'offer_version', p_offer_version));
    if (v_evt ->> 'processed')::boolean then
      return coalesce(v_evt -> 'result', '{}'::jsonb) || jsonb_build_object('replayed', true);
    end if;
  end if;
  v_result := app.finalize_booking(p_booking, 'payment', coalesce(p_processor, '{}'::jsonb), p_amount_cents, p_offer_version, p_card, p_by);
  if p_event_id is not null then
    perform app.webhook_event_finish(v_proc, p_event_id, v_result);
  end if;
  return v_result;
end $$;

-- A booking on which the renter owes nothing at booking: an insurer pays the whole bill (the
-- driver still saves a card, for the Deposit and anything the insurer does not cover), or an
-- Owner Booking (no card at all). Confirmed on the signature, with the same checks and lock.
create or replace function app.confirm_unpaid_booking(p_booking uuid, p_by uuid, p_card jsonb default null, p_processor jsonb default null)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  v_version integer;
begin
  if p_by is null or not (app.is_booking_renter(p_booking, p_by) or app.user_is_staff(p_by)) then
    raise exception 'Only the renter of this booking, or staff, confirms it' using errcode = '42501';
  end if;
  select offer_approved_version into v_version from bookings where id = p_booking;
  return app.finalize_booking(p_booking, 'nothing_due', coalesce(p_processor, '{}'::jsonb), 0, v_version, p_card, p_by);
end $$;

-- The capture of an authorized payment failed after the booking was confirmed (rare). The
-- payment is marked failed and an Admin decides: collect another way, or cancel.
create or replace function app.booking_payment_capture_failed(p_booking uuid, p_processor jsonb, p_error text default null) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_pay uuid;
begin
  select * into b from bookings where id = p_booking for update;
  if b.id is null then raise exception 'Booking % not found', p_booking; end if;
  select p.id into v_pay from payments p join payment_processor_details d on d.payment_id = p.id
   where p.booking_id = p_booking and p.purpose = 'booking_total' and p.status = 'succeeded'
     and d.processor = coalesce(nullif(p_processor ->> 'processor', ''), 'stripe') and d.processor_payment_id = p_processor ->> 'payment_id';
  if v_pay is null then
    raise exception 'No recorded payment on booking % matches this processor payment', b.booking_number using errcode = '22023';
  end if;
  update payments set status = 'failed', last_decline_code = left(coalesce(p_error, 'capture_failed'), 200) where id = v_pay;
  insert into tasks (queue, task_type, title, detail, procedure_no, priority, escalated, escalated_at, escalation_reason, booking_id, vehicle_id, renter_id)
  values ('admin', 'capture_failed', format('Booking %s is confirmed but its payment could not be captured', b.booking_number),
          coalesce(p_error, 'The processor refused the capture.') || ' Collect the amount another way or cancel the booking.', 1, 'urgent',
          true, now(), 'a confirmed booking is unpaid', p_booking, b.vehicle_id, b.renter_id);
  perform app.log_booking_event(p_booking, 'payment_refused', b.status::text, b.status::text, b.offer_approved_version,
    'The capture of the authorized payment failed after confirmation.', null, 'system', jsonb_build_object('payment_id', v_pay, 'error', p_error));
end $$;

-- ================================================================ bookings: what follows a change, and the handover guards
-- Separate triggers, so that app.booking_before_write() of migration 0016 is left as it is.
-- BEFORE triggers run in name order: this one ("bookings_handover_guard") runs after
-- bookings_before_write and after the column guards.
create or replace function app.booking_app_before() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  -- The Deposit waiver: an Admin's decision, with a reason, on a confirmed booking. Given once.
  if (new.deposit_waived_at, new.deposit_waived_by, new.deposit_waived_reason, new.deposit_waived_cents)
     is distinct from (old.deposit_waived_at, old.deposit_waived_by, old.deposit_waived_reason, old.deposit_waived_cents) then
    if old.deposit_waived_at is not null or new.deposit_waived_at is null then
      raise exception 'A Deposit waiver is given once, with who and why, and then stands' using errcode = '23514';
    end if;
    if not app.user_is_admin(new.deposit_waived_by) then
      raise exception 'Only an Admin waives the Deposit' using errcode = '42501';
    end if;
    if btrim(coalesce(new.deposit_waived_reason, '')) = '' then
      raise exception 'Waiving the Deposit needs a reason' using errcode = '23514';
    end if;
    if new.booking_type = 'owner' then
      raise exception 'An Owner Booking has no Deposit' using errcode = '23514';
    end if;
    if old.status <> 'confirmed' or new.status <> 'confirmed' then
      raise exception 'The Deposit is waived on a confirmed booking, before handover' using errcode = '23514';
    end if;
    if exists (select 1 from deposits d where d.booking_id = new.id and d.status in ('held', 'captured')) then
      raise exception 'The Deposit of this booking was already taken' using errcode = '23514';
    end if;
    new.deposit_waived_cents := old.deposit_cents;
    new.deposit_cents := 0;
  end if;

  if new.status is distinct from old.status then
    -- back to staff, or ended, while an agreement was open or signed but unpaid: that agreement
    -- no longer stands (the after trigger voids it) and the booking no longer points at it
    if old.status = 'pending_payment' and new.status in ('requested', 'declined', 'expired', 'cancelled')
       and new.signature_request_id is not null
       and exists (select 1 from rental_agreements a where a.signature_request_id = new.signature_request_id and a.status in ('open', 'signed')) then
      new.signature_request_id := null;
      new.agreement_document_id := null;
    end if;
    -- a question to the renter belongs to a request
    if new.status <> 'requested' then
      new.awaiting_renter_since := null;
    end if;

    -- handover: on top of what app.booking_before_write() already asks for (every driver's
    -- identity verified, a Coverage Option confirmed, the pickup Condition Report)
    if new.status = 'on_rent' then
      if not new.blocks_calendar then
        raise exception 'A booking that does not block the calendar cannot be handed over: turn the calendar switch on first'
          using errcode = '23514';
      end if;
      if exists (select 1 from booking_drivers d where d.booking_id = new.id and d.role = 'additional' and d.accepted_at is null) then
        raise exception 'No car is released until every additional driver has accepted the rental agreement' using errcode = '23514';
      end if;
      if new.booking_type <> 'owner' and new.deposit_waived_at is null
         and not exists (select 1 from deposits d where d.booking_id = new.id and d.status in ('held', 'captured')) then
        raise exception 'No car is released without the Deposit: it is taken at pickup, or waived by an Admin with a reason'
          using errcode = '23514';
      end if;
    end if;
  end if;
  return new;
end $$;
create trigger bookings_handover_guard before update on bookings
  for each row execute function app.booking_app_before();

create or replace function app.booking_app_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_days integer;
  v_from timestamptz;
begin
  if new.deposit_waived_at is not null and old.deposit_waived_at is null then
    perform app.log_booking_event(new.id, 'deposit_waived', new.status::text, new.status::text, null, new.deposit_waived_reason,
      new.deposit_waived_by, 'staff', jsonb_build_object('deposit_waived_cents', new.deposit_waived_cents));
  end if;

  if new.status is distinct from old.status then
    -- "a later adjustment voids unsigned and signed-but-unpaid agreements and requires signing again"
    if old.status = 'pending_payment' and new.status in ('requested', 'declined', 'expired', 'cancelled') then
      perform app.void_rental_agreements(new.id,
        case when new.status = 'requested'
             then 'The booking went back to staff after this agreement was opened: the next offer is approved and signed again'
             else 'The booking did not go ahead' end);
    end if;
    if old.status = 'requested' then
      update booking_info_requests set status = 'closed', closed_reason = 'The request moved on before an answer came'
       where booking_id = new.id and status = 'open';
    end if;
    if new.status in ('cancelled', 'no_show', 'declined', 'expired') then
      update booking_extensions set status = 'declined', declined_at = now(), decline_reason = 'The booking ended'
       where booking_id = new.id and status in ('requested', 'approved');
      update booking_change_requests set status = 'cancelled' where booking_id = new.id and status in ('requested', 'proposed', 'approved');
    end if;
  end if;

  -- the retention clock of licence images and face photos: so many days after the rental ends
  -- (or after the booking falls through); it moves with the return time until then
  if (new.status is distinct from old.status and new.status in ('returned', 'cancelled', 'no_show', 'declined', 'expired'))
     or new.return_at is distinct from old.return_at then
    v_days := (app.settings()).retention_id_face_days;
    v_from := case when new.status in ('returned', 'closed') then coalesce(new.checked_in_at, now())
                   when new.status in ('cancelled', 'no_show', 'declined', 'expired') then now()
                   else new.return_at end;
    update documents set purge_after = v_from + make_interval(days => v_days)
     where booking_id = new.id and retention = 'id_face_90d' and purged_at is null;
    update identity_verifications set purge_after = v_from + make_interval(days => v_days)
     where booking_id = new.id and purged_at is null;
  end if;
  return null;
end $$;
create trigger bookings_app_after after update on bookings
  for each row execute function app.booking_app_after();

-- Columns of this migration that a browser session may change only as an Admin (the server sets
-- them through the functions here), and the waiver is always signed with the Admin's own name.
create trigger bookings_guard_app_columns before update on bookings
  for each row execute function app.guard_admin_columns(
    'request_key', 'request_details', 'awaiting_renter_since',
    'deposit_waived_at', 'deposit_waived_by', 'deposit_waived_reason', 'deposit_waived_cents');
create trigger bookings_guard_waiver_approver before update on bookings
  for each row execute function app.guard_approver('deposit_waived_by');
create trigger booking_extensions_guard_approver before insert or update on booking_extensions
  for each row execute function app.guard_approver('approved_by', 'declined_by');

-- An Admin waives the Deposit of a confirmed booking, with a reason. The amount waived is kept.
create or replace function app.waive_deposit(p_booking uuid, p_by uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  if not app.user_is_admin(p_by) then
    raise exception 'Only an Admin waives the Deposit' using errcode = '42501';
  end if;
  update bookings set deposit_waived_at = now(), deposit_waived_by = p_by, deposit_waived_reason = p_reason where id = p_booking;
  if not found then raise exception 'Booking % not found', p_booking; end if;
end $$;

-- ================================================================ cancellation
-- What the renter has paid on a booking and not had back: card charges for the booking and its
-- extensions and changes, less refunds approved or paid.
create or replace function app.booking_paid_cents(p_booking uuid) returns bigint
language sql stable security definer set search_path = public, app as $$
  select greatest(0,
           coalesce((select sum(p.amount_cents) from payments p
                      where p.booking_id = p_booking and p.status = 'succeeded' and p.kind = 'charge'
                        and p.purpose in ('booking_total', 'extension')), 0)
         - coalesce((select sum(r.amount_cents) from refunds r
                      where r.booking_id = p_booking and r.status in ('approved', 'processing', 'paid')), 0))
$$;

-- What a cancellation received at p_at would give back: the tier, the percentage and the
-- amounts, from public.calc_cancellation() (renter billing specification section 5). Read only.
-- "Booking made" is the moment the booking was confirmed (signed and paid); a booking written
-- in the old way without that moment uses when it was made.
create or replace function app.preview_cancellation(p_booking uuid, p_at timestamptz default now(), p_reason text default 'renter_request')
returns jsonb language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  r record;
  v_paid bigint;
  v_made timestamptz;
  v_received timestamptz;
  v_dep record;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null then raise exception 'Booking % not found', p_booking; end if;
  if p_reason not in ('renter_request', 'no_show', 'false_documents', 'no_coverage_at_pickup', 'carmacars_no_vehicle', 'driver_not_verifiable') then
    raise exception 'A cancellation for the reason "%" has its refund set by an Admin', p_reason using errcode = '23514';
  end if;
  v_paid := app.booking_paid_cents(p_booking);
  v_made := coalesce(b.confirmed_at, b.booked_at);
  v_received := case when p_reason = 'no_show' then greatest(p_at, b.pickup_at) else p_at end;
  select * into r from public.calc_cancellation(v_made, v_received, b.pickup_at, b.booking_type = 'non_refundable', v_paid,
                                                p_reason in ('carmacars_no_vehicle', 'driver_not_verifiable'));
  select d.status, d.amount_cents, d.captured_cents into v_dep from deposits d where d.booking_id = p_booking;
  return jsonb_build_object(
    'booking_id', b.id, 'booking_number', b.booking_number, 'status', b.status, 'can_cancel', b.status = 'confirmed',
    'reason', p_reason, 'booking_made_at', v_made, 'received_at', v_received, 'start_at', b.pickup_at,
    'non_refundable', b.booking_type = 'non_refundable', 'total_paid_cents', v_paid,
    'tier', r.tier, 'refund_bps', r.refund_bps, 'refund_cents', r.refund_cents, 'retained_cents', r.retained_cents,
    'deposit_returned_cents', coalesce(v_dep.captured_cents, 0), 'deposit_hold_to_release', coalesce(v_dep.status = 'held', false),
    'refund_due_by', app.add_business_days(app.local_date(p_at), (app.settings()).refund_business_days));
end $$;

-- Cancel a confirmed booking. The renter cancels their own (reason 'renter_request'); customer
-- service or an Admin logs a cancellation for any of the reasons the table covers, a no-show
-- included. The tier is worked out by the database, the refund waits for approval within the
-- usual limits, and Finance gets the task. Returns the preview, with the refund's id.
create or replace function app.cancel_booking(p_booking uuid, p_by uuid, p_reason text default 'renter_request', p_note text default null,
                                              p_channel text default 'portal', p_at timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  c booking_cancellations;
  v_staff boolean := app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs');
  v_renter boolean := app.is_booking_renter(p_booking, p_by);
  v_preview jsonb;
  v_by_cc boolean := p_reason in ('carmacars_no_vehicle', 'driver_not_verifiable');
  v_pay uuid;
  v_refund uuid;
  v_to booking_status;
begin
  select * into b from bookings where id = p_booking for update;
  if b.id is null then raise exception 'Booking % not found', p_booking; end if;
  if p_by is null or not (v_staff or v_renter) then
    raise exception 'Only the renter of this booking, customer service or an Admin cancels it' using errcode = '42501';
  end if;
  if not v_staff and (p_reason <> 'renter_request' or p_at is distinct from now()) then
    raise exception 'A renter cancels their own booking, now' using errcode = '42501';
  end if;
  if b.status <> 'confirmed' then
    raise exception 'Booking % is %: only a confirmed booking is cancelled (a request is withdrawn or declined)', b.booking_number, b.status
      using errcode = '23514';
  end if;
  if p_reason = 'no_show' and p_at < b.pickup_at then
    raise exception 'A no-show is logged after the pickup time' using errcode = '23514';
  end if;
  v_preview := app.preview_cancellation(p_booking, p_at, p_reason);
  v_to := case when p_reason = 'no_show' then 'no_show'::booking_status else 'cancelled'::booking_status end;

  insert into booking_cancellations (booking_id, booked_at, received_at, start_at, channel, cancelled_by, reason, total_paid_cents, logged_by)
  values (p_booking, (v_preview ->> 'booking_made_at')::timestamptz, p_at, b.pickup_at, p_channel,
          case when v_by_cc then 'carmacars' else 'renter' end, p_reason, (v_preview ->> 'total_paid_cents')::bigint, p_by)
  returning * into c;
  update bookings set status = v_to where id = p_booking;

  if c.refund_cents > 0 then
    select p.id into v_pay from payments p
     where p.booking_id = p_booking and p.purpose = 'booking_total' and p.kind = 'charge' and p.status = 'succeeded'
     order by p.processed_at desc nulls last, p.created_at desc limit 1;
    insert into refunds (booking_id, payment_id, reason, refund_bps, amount_cents, status, requested_by, note)
    values (p_booking, v_pay, case p_reason when 'carmacars_no_vehicle' then 'carmacars_cancelled' when 'driver_not_verifiable' then 'driver_not_verifiable'
                                            else 'cancellation' end,
            c.refund_bps, c.refund_cents, 'pending_approval', p_by, p_note)
    returning id into v_refund;
    update booking_cancellations set refund_id = v_refund where booking_id = p_booking;
    if b.bill_to = 'renter' then
      perform app.allocate_refund(v_refund);
    end if;
  end if;
  insert into tasks (queue, task_type, title, detail, procedure_no, priority, booking_id, vehicle_id, renter_id, related_table, related_id)
  values ('finance', 'cancellation_refund', format('Booking %s was cancelled', b.booking_number),
          format('Tier %s: refund of %s cents (%s basis points of %s paid), kept %s. %s', c.tier, c.refund_cents, c.refund_bps, c.total_paid_cents,
                 c.retained_cents,
                 case when c.refund_cents > 0 then 'Approve and pay the refund within the refund period.' else 'No refund applies.' end
                 || case when (v_preview ->> 'deposit_hold_to_release')::boolean or c.deposit_returned_cents > 0
                         then ' Any Deposit already taken is returned in full.' else '' end),
          1, 'high', p_booking, b.vehicle_id, b.renter_id, case when v_refund is not null then 'refunds' end, v_refund);
  perform app.log_booking_event(p_booking, 'cancelled', 'confirmed', v_to::text, null, p_note, p_by, null,
    jsonb_build_object('reason', p_reason, 'tier', c.tier, 'refund_bps', c.refund_bps, 'refund_cents', c.refund_cents,
                       'retained_cents', c.retained_cents, 'refund_id', v_refund));
  return v_preview || jsonb_build_object('cancelled', true, 'status', v_to, 'tier', c.tier, 'refund_bps', c.refund_bps,
                                         'refund_cents', c.refund_cents, 'retained_cents', c.retained_cents, 'refund_id', v_refund);
end $$;

-- ================================================================ extensions
-- What extending a booking to p_new_return would cost (renter billing specification section 6):
-- the whole booking repriced at its new length at the rates stored on it, the difference in the
-- rental charge, the per-day fees up to their caps, and HST. Read only. "problems" lists why it
-- cannot go ahead (too long, too late, the car is booked next); "ok" is true when there is none.
create or replace function app.preview_extension(p_booking uuid, p_new_return timestamptz, p_now timestamptz default now())
returns jsonb language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  v_set program_settings := app.settings();
  v_booked program_settings;
  v_problems jsonb := '[]'::jsonb;
  v_new_days integer;
  x record;
  v_old jsonb; v_new jsonb;
  v_lines jsonb := '[]'::jsonb;
  v_rental bigint;
  v_disc bigint := 0;
  v_promo bigint := 0;
  v_fees bigint; v_hst bigint;
  v_available boolean;
  v_capture boolean;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null then raise exception 'Booking % not found', p_booking; end if;
  v_booked := app.settings(app.local_date(b.booked_at));
  if b.status not in ('confirmed', 'on_rent') then
    v_problems := v_problems || jsonb_build_object('code', 'not_extendable', 'message', format('A booking that is %s cannot be extended.', b.status));
  end if;
  if p_new_return is null or p_new_return <= b.return_at then
    v_problems := v_problems || jsonb_build_object('code', 'not_later', 'message', 'The new return must be after the current return.');
    return jsonb_build_object('ok', false, 'problems', v_problems, 'booking_id', b.id, 'previous_return_at', b.return_at, 'new_return_at', p_new_return);
  end if;
  if p_now >= b.return_at then
    v_problems := v_problems || jsonb_build_object('code', 'too_late', 'message', 'An extension is asked for, confirmed and paid before the current return time.');
  end if;
  v_new_days := public.calc_billable_days(b.pickup_at, p_new_return);
  if v_new_days > least(v_set.max_rental_days, 30) then
    v_problems := v_problems || jsonb_build_object('code', 'over_maximum_length',
      'message', format('The total length stays at %s days or less. A longer stay is a renewal: a new booking and agreement.', least(v_set.max_rental_days, 30)));
    return jsonb_build_object('ok', false, 'problems', v_problems, 'booking_id', b.id, 'previous_return_at', b.return_at,
                              'new_return_at', p_new_return, 'previous_days', b.billable_days, 'new_days', v_new_days);
  end if;
  if b.booking_type = 'owner' then
    v_rental := 0;
  else
    select * into x from public.calc_extension(b.pickup_at, b.billable_days, v_new_days,
                                               b.daily_rate_cents, b.weekend_rate_cents, b.weekly_rate_cents, b.monthly_rate_cents);
    v_rental := x.rental_difference_cents;
    -- the discounts follow the rental charge: the non-refundable discount stays its fixed
    -- share, a percentage promo code keeps its percentage
    if b.booking_type = 'non_refundable' then
      v_disc := public.calc_bps(b.rental_charge_cents + v_rental, v_booked.non_refundable_discount_bps) - b.discount_cents;
    end if;
    if b.promo_code_id is not null then
      v_promo := coalesce(app.promo_discount_cents(b.promo_code_id,
                   b.rental_charge_cents + v_rental - (b.discount_cents + v_disc) - b.staff_discount_cents), 0) - b.promo_discount_cents;
    end if;
    if v_rental <> 0 then v_lines := v_lines || app.price_line('rental_charge', 1, v_rental, v_rental, b.hst_bps, 'Rental charge for the added time'); end if;
    if v_disc <> 0 then v_lines := v_lines || app.price_line('non_refundable_discount', 1, -v_disc, -v_disc, b.hst_bps); end if;
    if v_promo <> 0 then v_lines := v_lines || app.price_line('promo_discount', 1, -v_promo, -v_promo, b.hst_bps); end if;
    -- per-day fees, each up to its cap for the whole rental
    v_old := app.price_lines(app.booking_price_spec(p_booking, jsonb_build_object('managed', true, 'recompute_rental', true)));
    v_new := app.price_lines(app.booking_price_spec(p_booking, jsonb_build_object('managed', true, 'return_at', p_new_return)));
    select v_lines || coalesce(jsonb_agg(app.price_line(n.value ->> 'charge_type', 1,
                                  (n.value ->> 'amount_cents')::bigint - coalesce((o.value ->> 'amount_cents')::bigint, 0),
                                  (n.value ->> 'amount_cents')::bigint - coalesce((o.value ->> 'amount_cents')::bigint, 0),
                                  b.hst_bps, n.value ->> 'description', (n.value ->> 'driver_id')::uuid, n.value -> 'detail') order by n.ord), '[]'::jsonb)
      into v_lines
      from jsonb_array_elements(v_new -> 'lines') with ordinality n(value, ord)
      left join jsonb_array_elements(v_old -> 'lines') o(value)
        on o.value ->> 'charge_type' = n.value ->> 'charge_type' and (o.value ->> 'driver_id') is not distinct from (n.value ->> 'driver_id')
     where n.value ->> 'charge_type' in ('young_driver_18_20', 'young_driver_21_25', 'additional_driver', 'winter_tire', 'baby_seat')
       and (n.value ->> 'amount_cents')::bigint <> coalesce((o.value ->> 'amount_cents')::bigint, 0);
  end if;
  select coalesce(sum((l.value ->> 'amount_cents')::bigint) filter (where l.value ->> 'charge_type' <> 'rental_charge'), 0),
         coalesce(sum((l.value ->> 'hst_cents')::bigint), 0)
    into v_fees, v_hst from jsonb_array_elements(v_lines) l;

  v_available := not b.blocks_calendar or app.vehicle_is_available(b.vehicle_id, b.return_at, p_new_return, b.id);
  if not v_available then
    v_problems := v_problems || jsonb_build_object('code', 'not_available', 'message', 'The car is booked or blocked for part of the added time.');
  end if;
  v_capture := v_new_days > v_set.deposit_hold_max_days
               and exists (select 1 from deposits d where d.booking_id = p_booking and d.method = 'card_hold' and d.status = 'held');
  return jsonb_build_object('ok', jsonb_array_length(v_problems) = 0, 'problems', v_problems, 'booking_id', b.id,
    'previous_return_at', b.return_at, 'new_return_at', p_new_return, 'previous_days', b.billable_days, 'new_days', v_new_days,
    'previous_rental_charge_cents', b.rental_charge_cents, 'new_rental_charge_cents', b.rental_charge_cents + v_rental,
    'rental_difference_cents', v_rental, 'fees_difference_cents', v_fees, 'hst_cents', v_hst,
    'total_cents', v_rental + v_fees + v_hst, 'lines', v_lines, 'available', v_available,
    'km_allowance_total', b.km_allowance_per_day * v_new_days,
    'deposit_hold_capture_needed', v_capture);
end $$;

-- The renter (or staff for them) asks to extend. Priced at once; staff approve it, the renter
-- pays before the current return time, and only then does the return time move.
create or replace function app.request_extension(p_booking uuid, p_by uuid, p_new_return timestamptz, p_note text default null)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v jsonb;
  v_id uuid;
begin
  select * into b from bookings where id = p_booking for update;
  if b.id is null then raise exception 'Booking % not found', p_booking; end if;
  if p_by is null or not (app.is_booking_renter(p_booking, p_by) or app.user_is_staff(p_by)) then
    raise exception 'Only the renter of this booking, or staff, asks for an extension' using errcode = '42501';
  end if;
  if exists (select 1 from booking_extensions e where e.booking_id = p_booking and e.status in ('requested', 'approved')) then
    raise exception 'An extension request is already open on booking %', b.booking_number using errcode = '23514';
  end if;
  v := app.preview_extension(p_booking, p_new_return);
  if not (v ->> 'ok')::boolean then
    raise exception '%', v -> 'problems' -> 0 ->> 'message' using errcode = '23514';
  end if;
  insert into booking_extensions (booking_id, seq, status, previous_return_at, new_return_at, previous_days, new_days,
      previous_rental_charge_cents, new_rental_charge_cents, rental_difference_cents, fees_difference_cents, hst_cents, total_cents,
      requested_by, note, lines)
  values (p_booking, (select coalesce(max(e.seq), 0) + 1 from booking_extensions e where e.booking_id = p_booking), 'requested',
      b.return_at, p_new_return, b.billable_days, (v ->> 'new_days')::integer,
      (v ->> 'previous_rental_charge_cents')::bigint, (v ->> 'new_rental_charge_cents')::bigint, (v ->> 'rental_difference_cents')::bigint,
      (v ->> 'fees_difference_cents')::bigint, (v ->> 'hst_cents')::bigint, (v ->> 'total_cents')::bigint,
      p_by, nullif(btrim(coalesce(p_note, '')), ''), v -> 'lines')
  returning id into v_id;
  insert into tasks (queue, task_type, title, detail, procedure_no, priority, due_at, booking_id, vehicle_id, renter_id, related_table, related_id)
  values ('cs', 'extension_requested', format('Booking %s: extension asked for', b.booking_number),
          'Check the calendar, unpaid charges and coverage to the new return date, then approve or decline. It must be paid before the current return time.',
          1, 'high', b.return_at, p_booking, b.vehicle_id, b.renter_id, 'booking_extensions', v_id);
  perform app.log_booking_event(p_booking, 'extension', b.status::text, b.status::text, null, p_note, p_by, null,
    jsonb_build_object('extension_id', v_id, 'step', 'requested', 'new_return_at', p_new_return, 'total_cents', (v ->> 'total_cents')::bigint));
  perform app.emit_event('renter_extension_requested', 'booking_extension', v_id,
    jsonb_build_object('booking_id', p_booking, 'booking_number', b.booking_number, 'new_return_at', p_new_return,
                       'previous_return_at', b.return_at, 'total_cents', (v ->> 'total_cents')::bigint),
    'renter_extension_requested:' || v_id || ':requested');
  perform app.emit_event('staff_extension_requested', 'booking_extension', v_id,
    jsonb_build_object('booking_id', p_booking, 'booking_number', b.booking_number, 'new_return_at', p_new_return,
                       'previous_return_at', b.return_at, 'total_cents', (v ->> 'total_cents')::bigint),
    'staff_extension_requested:' || v_id || ':requested');
  return v_id;
end $$;

-- Staff approve an extension request: priced again as of now, the calendar and the coverage
-- checked to the new return. The renter then pays; nothing moves until they do.
create or replace function app.approve_extension(p_extension uuid, p_by uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  e booking_extensions;
  b bookings;
  v jsonb;
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'fleet')) then
    raise exception 'Only customer service, fleet or an Admin approves an extension' using errcode = '42501';
  end if;
  select * into e from booking_extensions where id = p_extension for update;
  if e.id is null then raise exception 'Extension % not found', p_extension; end if;
  select * into b from bookings where id = e.booking_id for update;
  if e.status <> 'requested' then
    raise exception 'This extension is %: only a requested one is approved', e.status using errcode = '23514';
  end if;
  v := app.preview_extension(e.booking_id, e.new_return_at);
  if not (v ->> 'ok')::boolean then
    raise exception '%', v -> 'problems' -> 0 ->> 'message' using errcode = '23514';
  end if;
  if exists (select 1 from coverage_proofs c where c.booking_id = e.booking_id and c.status = 'confirmed' and c.coverage_option = 1
                and c.policy_expiry < app.local_date(e.new_return_at)) then
    raise exception 'The renter''s coverage ends before the new return date: new proof is needed first' using errcode = '23514';
  end if;
  update booking_extensions
     set status = 'approved', approved_by = p_by, approved_at = now(), previous_days = b.billable_days, new_days = (v ->> 'new_days')::integer,
         previous_rental_charge_cents = (v ->> 'previous_rental_charge_cents')::bigint, new_rental_charge_cents = (v ->> 'new_rental_charge_cents')::bigint,
         rental_difference_cents = (v ->> 'rental_difference_cents')::bigint, fees_difference_cents = (v ->> 'fees_difference_cents')::bigint,
         hst_cents = (v ->> 'hst_cents')::bigint, total_cents = (v ->> 'total_cents')::bigint, lines = v -> 'lines'
   where id = p_extension;
  perform app.log_booking_event(e.booking_id, 'extension', b.status::text, b.status::text, null, null, p_by, 'staff',
    jsonb_build_object('extension_id', e.id, 'step', 'approved', 'new_return_at', e.new_return_at, 'total_cents', (v ->> 'total_cents')::bigint));
  perform app.emit_event('renter_extension_approved', 'booking_extension', e.id,
    jsonb_build_object('booking_id', e.booking_id, 'booking_number', b.booking_number, 'new_return_at', e.new_return_at,
                       'previous_return_at', e.previous_return_at, 'total_cents', (v ->> 'total_cents')::bigint, 'pay_before', e.previous_return_at),
    'renter_extension_approved:' || e.id || ':approved');
  return v || jsonb_build_object('extension_id', e.id, 'status', 'approved');
end $$;

-- Staff decline an extension request with a reason; or the renter withdraws their own.
create or replace function app.decline_extension(p_extension uuid, p_by uuid, p_reason text default null) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  e booking_extensions;
  b bookings;
  v_staff boolean := app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'fleet');
begin
  select * into e from booking_extensions where id = p_extension for update;
  if e.id is null then raise exception 'Extension % not found', p_extension; end if;
  select * into b from bookings where id = e.booking_id;
  if p_by is null or not (v_staff or app.is_booking_renter(e.booking_id, p_by)) then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if e.status not in ('requested', 'approved') then
    raise exception 'This extension is % and is no longer open', e.status using errcode = '23514';
  end if;
  if v_staff and nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'Declining an extension needs a reason' using errcode = '22023';
  end if;
  update booking_extensions set status = 'declined', declined_by = p_by, declined_at = now(),
         decline_reason = coalesce(nullif(btrim(coalesce(p_reason, '')), ''), 'Withdrawn by the renter')
   where id = p_extension;
  perform app.log_booking_event(e.booking_id, 'extension', b.status::text, b.status::text, null, p_reason, p_by, null,
    jsonb_build_object('extension_id', e.id, 'step', case when v_staff then 'declined' else 'withdrawn' end));
  if v_staff then
    perform app.emit_event('renter_extension_declined', 'booking_extension', e.id,
      jsonb_build_object('booking_id', e.booking_id, 'booking_number', b.booking_number, 'new_return_at', e.new_return_at, 'decline_reason', p_reason),
      'renter_extension_declined:' || e.id || ':declined');
  end if;
end $$;

-- The renter has paid an approved extension (or nothing was due): under the lock on the
-- vehicle the calendar is checked once more, the payment and the extension's charge lines are
-- recorded, the booking's return time moves, and the extension is confirmed in writing (the
-- confirmation email follows from the event). Refusals are returned, with what the server must
-- do about the money: {ok: false, action: 'refund_payment', reason}.
create or replace function app.confirm_extension_payment(p_extension uuid, p_processor jsonb, p_amount_cents bigint,
                                                         p_at timestamptz default now(), p_by uuid default null)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  e booking_extensions;
  b bookings;
  v_set program_settings := app.settings();
  v_vehicle uuid;
  v_proc text := coalesce(nullif(p_processor ->> 'processor', ''), 'stripe');
  v_pp text := nullif(p_processor ->> 'payment_id', '');
  v_pay uuid;
  v_reason text;
  v_disc bigint; v_promo bigint;
  r record;
begin
  select o.vehicle_id into v_vehicle from booking_extensions x join bookings o on o.id = x.booking_id where x.id = p_extension;
  if v_vehicle is null then raise exception 'Extension % not found', p_extension; end if;
  perform 1 from vehicles where id = v_vehicle for no key update;
  select * into e from booking_extensions where id = p_extension for update;
  select * into b from bookings where id = e.booking_id for update;

  if e.status = 'confirmed' then
    return jsonb_build_object('ok', true, 'already_confirmed', true, 'extension_id', e.id, 'booking_id', b.id, 'payment_id', e.payment_id,
                              'return_at', b.return_at);
  end if;
  v_reason := case
    when e.status <> 'approved' then 'not_approved'
    when b.status not in ('confirmed', 'on_rent') then 'booking_not_live'
    when p_at > e.previous_return_at or b.return_at <> e.previous_return_at then 'lapsed'
    when p_amount_cents is distinct from e.total_cents then 'amount_mismatch'
    when e.total_cents > 0 and v_pp is null then 'payment_needed'
    when b.blocks_calendar and not app.vehicle_is_available(b.vehicle_id, b.return_at, e.new_return_at, b.id) then 'vehicle_taken'
    when e.new_days > v_set.deposit_hold_max_days
         and exists (select 1 from deposits d where d.booking_id = b.id and d.method = 'card_hold' and d.status = 'held') then 'capture_deposit_first'
  end;
  if v_reason is not null then
    if v_reason = 'lapsed' and e.status in ('requested', 'approved') then
      update booking_extensions set status = 'lapsed' where id = e.id;
    end if;
    return jsonb_build_object('ok', false, 'extension_id', e.id, 'booking_id', b.id, 'reason', v_reason,
      'action', case when v_pp is not null then 'refund_payment' else 'none' end,
      'message', case v_reason
        when 'not_approved' then format('This extension is %s, not approved and waiting for payment.', e.status)
        when 'booking_not_live' then format('Booking %s is %s.', b.booking_number, b.status)
        when 'lapsed' then 'The extension was not paid before the return time. It has lapsed.'
        when 'amount_mismatch' then 'The amount does not equal the price of the extension.'
        when 'payment_needed' then 'The extension has a price: its payment is needed.'
        when 'vehicle_taken' then 'The car was booked for the added time before the extension was paid.'
        else 'The rental is now longer than a card hold lasts: capture the Deposit hold as a charged Deposit first.' end,
      'expected_cents', e.total_cents);
  end if;

  if e.total_cents > 0 then
    insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, payment_method_id, processed_at, created_by)
    values (b.id, b.renter_id, 'extension', 'charge', 'card', p_amount_cents, 'succeeded', b.card_on_file_id, p_at, p_by)
    returning id into v_pay;
    insert into payment_processor_details (payment_id, processor, processor_payment_id, processor_charge_id, receipt_url)
    values (v_pay, v_proc, v_pp, p_processor ->> 'charge_id', p_processor ->> 'receipt_url');
  end if;
  insert into booking_line_items (booking_id, charge_type, description, quantity, unit_amount_cents, amount_cents, hst_applies, hst_cents,
                                  revenue_class, stage, driver_id, extension_id, payment_id)
  select b.id, l.value ->> 'charge_type', l.value ->> 'description', 1, (l.value ->> 'amount_cents')::bigint, (l.value ->> 'amount_cents')::bigint,
         (l.value ->> 'hst_applies')::boolean, (l.value ->> 'hst_cents')::bigint, (l.value ->> 'revenue_class')::revenue_class,
         'extension', (l.value ->> 'driver_id')::uuid, e.id, v_pay
    from jsonb_array_elements(coalesce(e.lines, '[]'::jsonb)) l;
  select coalesce(-sum((l.value ->> 'amount_cents')::bigint) filter (where l.value ->> 'charge_type' = 'non_refundable_discount'), 0),
         coalesce(-sum((l.value ->> 'amount_cents')::bigint) filter (where l.value ->> 'charge_type' = 'promo_discount'), 0)
    into v_disc, v_promo from jsonb_array_elements(coalesce(e.lines, '[]'::jsonb)) l;
  select * into r from public.calc_rental_charge(b.pickup_at, e.new_days, b.daily_rate_cents, b.weekend_rate_cents, b.weekly_rate_cents, b.monthly_rate_cents);
  update bookings
     set return_at = e.new_return_at, billable_days = e.new_days, km_allowance_total = km_allowance_per_day * e.new_days,
         rental_charge_cents = e.new_rental_charge_cents, discount_cents = discount_cents + v_disc,
         promo_discount_cents = promo_discount_cents + v_promo,
         rate_applied = case when booking_type = 'owner' then 'none' else r.rate_applied end,
         daily_days = r.daily_days, weekend_days = r.weekend_days
   where id = b.id;
  update booking_extensions
     set status = 'confirmed', payment_id = v_pay, paid_at = p_at, confirmed_in_writing_at = p_at, confirmed_by = p_by,
         deposit_hold_captured = e.new_days > v_set.deposit_hold_max_days
                                 and exists (select 1 from deposits d where d.booking_id = b.id and d.status = 'captured')
   where id = e.id;
  perform app.log_booking_event(b.id, 'extension', b.status::text, b.status::text, null, null, p_by, case when p_by is null then 'system' end,
    jsonb_build_object('extension_id', e.id, 'step', 'confirmed', 'new_return_at', e.new_return_at, 'payment_id', v_pay, 'total_cents', e.total_cents));
  perform app.emit_event('renter_extension_confirmed', 'booking_extension', e.id,
    jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number, 'new_return_at', e.new_return_at,
                       'previous_return_at', e.previous_return_at, 'total_cents', e.total_cents, 'payment_id', v_pay),
    'renter_extension_confirmed:' || e.id || ':confirmed');
  return jsonb_build_object('ok', true, 'extension_id', e.id, 'booking_id', b.id, 'payment_id', v_pay, 'return_at', e.new_return_at,
                            'billable_days', e.new_days, 'action', 'none');
end $$;

-- Extension requests not confirmed and paid by the return time they would have moved lapse.
-- Safe to run at any time. Returns how many lapsed.
create or replace function app.lapse_extensions(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  n integer;
begin
  update booking_extensions set status = 'lapsed' where status in ('requested', 'approved') and previous_return_at <= p_now;
  get diagnostics n = row_count;
  return n;
end $$;

-- ================================================================ changes to a confirmed booking
-- What changing the dates or the car of a confirmed booking would do to its price. Read only.
-- p_changes: pickup_at, return_at, vehicle_id. Priced at the rates stored on the booking; a
-- rental charge an Admin set by hand keeps its difference from the rate rule.
create or replace function app.preview_booking_change(p_booking uuid, p_changes jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  v2 vehicles;
  v_set program_settings := app.settings();
  ch jsonb := coalesce(p_changes, '{}'::jsonb);
  k text;
  v_vehicle uuid; v_pickup timestamptz; v_return timestamptz;
  v_problems jsonb := '[]'::jsonb;
  v_days integer;
  o record; n record;
  v_rental bigint;
  v_new jsonb;
  v_owned text[] := array['rental_charge', 'non_refundable_discount', 'staff_discount', 'promo_discount', 'delivery', 'pickup'];
  v_other bigint; v_other_hst bigint;
  v_sub bigint; v_hst bigint;
  v_available boolean := true;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null then raise exception 'Booking % not found', p_booking; end if;
  if jsonb_typeof(ch) <> 'object' then raise exception 'Give the changes as a JSON object' using errcode = '22023'; end if;
  for k in select jsonb_object_keys(ch) loop
    if k not in ('pickup_at', 'return_at', 'vehicle_id') then
      raise exception 'Unknown change "%": a confirmed booking may change its dates or its car', k using errcode = '22023';
    end if;
  end loop;
  v_vehicle := coalesce((ch ->> 'vehicle_id')::uuid, b.vehicle_id);
  v_pickup := coalesce((ch ->> 'pickup_at')::timestamptz, b.pickup_at);
  v_return := coalesce((ch ->> 'return_at')::timestamptz, b.return_at);
  if v_return <= v_pickup then raise exception 'The return must be after the pickup' using errcode = '22023'; end if;
  if (v_vehicle, v_pickup, v_return) is not distinct from (b.vehicle_id, b.pickup_at, b.return_at) then
    v_problems := v_problems || jsonb_build_object('code', 'nothing_changes', 'message', 'These are the dates and the car the booking already has.');
  end if;
  if b.status <> 'confirmed' then
    v_problems := v_problems || jsonb_build_object('code', 'not_confirmed',
      'message', format('Booking %s is %s. A change request is for a confirmed booking that has not started.', b.booking_number, b.status));
  end if;
  if b.dates_provisional or b.bill_to <> 'renter' then
    v_problems := v_problems || jsonb_build_object('code', 'insurer_booking', 'message', 'A booking billed to an insurer is changed by staff.');
  end if;
  if exists (select 1 from booking_extensions e where e.booking_id = p_booking and e.status in ('requested', 'approved', 'confirmed')) then
    v_problems := v_problems || jsonb_build_object('code', 'has_extension', 'message', 'A booking with an extension is changed by staff.');
  end if;
  if v_pickup <> b.pickup_at and v_pickup < now() then
    v_problems := v_problems || jsonb_build_object('code', 'pickup_in_past', 'message', 'The new pickup time has already passed.');
  end if;
  v_days := public.calc_billable_days(v_pickup, v_return);
  if v_days > least(v_set.max_rental_days, 30) then
    v_problems := v_problems || jsonb_build_object('code', 'over_maximum_length',
      'message', format('A rental is %s days or less. A longer stay is a renewal.', least(v_set.max_rental_days, 30)));
    return jsonb_build_object('ok', false, 'problems', v_problems, 'booking_id', b.id);
  end if;
  if v_vehicle <> b.vehicle_id then
    select * into v2 from vehicles where id = v_vehicle;
    if v2.id is null then raise exception 'Vehicle not found' using errcode = '22023'; end if;
    if b.booking_type <> 'owner' and not coalesce(app.vehicle_bookable(v_vehicle), false) then
      v_problems := v_problems || jsonb_build_object('code', 'vehicle_not_bookable', 'message', 'That car is not open for bookings.');
    end if;
    -- A confirmed booking keeps the owner, management mode and Revenue Share stored on it
    -- (app.booking_before_write refuses a change), so the other car must share all three.
    if v2.owner_id <> b.owner_id or v2.management_mode <> b.management_mode or v2.is_shareholder_owned <> b.is_shareholder_vehicle
       or (b.booking_type <> 'owner' and not v2.is_shareholder_owned and v2.management_mode <> 'self_managed'
           and coalesce((app.vehicle_terms(v2.id, app.local_date(b.booked_at))).revenue_share_bps,
                        (select s.revenue_share_bps from vehicle_schedules s where s.vehicle_id = v2.id and s.superseded_by is null))
               is distinct from b.company_share_bps) then
      v_problems := v_problems || jsonb_build_object('code', 'other_owner_vehicle',
        'message', 'A confirmed booking can move only to a car of the same Owner on the same terms. For another Owner''s car, cancel for CarmaCars and make a new booking.');
    end if;
    if exists (select 1 from booking_drivers d where d.booking_id = p_booking
                  and app.age_band(app.age_on(d.date_of_birth, app.local_date(v_pickup))) = '18_to_20') and not v2.allows_18_to_20 then
      v_problems := v_problems || jsonb_build_object('code', 'vehicle_not_for_young_drivers',
        'message', format('That car is for drivers %s and over.', v_set.standard_min_age));
    end if;
  else
    select * into v2 from vehicles where id = b.vehicle_id;
  end if;
  if v2.exit_date is not null and app.local_date(v_return) > v2.exit_date then
    v_problems := v_problems || jsonb_build_object('code', 'vehicle_leaving', 'message', 'The car is not offered for the whole of these dates.');
  end if;
  if exists (select 1 from booking_drivers d where d.booking_id = p_booking
                and app.age_on(d.date_of_birth, app.local_date(v_pickup)) < v_set.min_renter_age) then
    v_problems := v_problems || jsonb_build_object('code', 'driver_under_minimum_age',
      'message', format('Every driver must be %s or older at pickup.', v_set.min_renter_age));
  end if;
  if b.blocks_calendar then
    v_available := app.vehicle_is_available(v_vehicle, v_pickup, v_return, b.id);
    if not v_available then
      v_problems := v_problems || jsonb_build_object('code', 'not_available', 'message', 'The car is not free for the whole of these dates.');
    end if;
  end if;

  -- the price after the change
  if b.booking_type = 'owner' then
    v_rental := 0;
  else
    select * into o from public.calc_rental_charge(b.pickup_at, b.billable_days, b.daily_rate_cents, b.weekend_rate_cents, b.weekly_rate_cents, b.monthly_rate_cents);
    select * into n from public.calc_rental_charge(v_pickup, v_days, b.daily_rate_cents, b.weekend_rate_cents, b.weekly_rate_cents, b.monthly_rate_cents);
    v_rental := greatest(0, b.rental_charge_cents + n.rental_charge_cents - o.rental_charge_cents);
  end if;
  v_new := app.price_lines(app.booking_price_spec(p_booking, ch || jsonb_build_object('rental_charge_cents', v_rental)));
  if b.request_details is not null then
    v_owned := v_owned || array['young_driver_18_20', 'young_driver_21_25', 'additional_driver', 'winter_tire', 'baby_seat', 'coverage_sold'];
  end if;
  -- lines staff entered by hand stay as they are
  select coalesce(sum(li.amount_cents), 0), coalesce(sum(li.hst_cents), 0) into v_other, v_other_hst
    from booking_line_items li
   where li.booking_id = p_booking and li.stage = 'booking' and li.charged_to_renter and li.voided_at is null
     and not li.charge_type = any (v_owned);
  v_sub := (v_new ->> 'subtotal_cents')::bigint + v_other;
  v_hst := (v_new ->> 'hst_cents')::bigint + v_other_hst;
  return jsonb_build_object('ok', jsonb_array_length(v_problems) = 0, 'problems', v_problems, 'booking_id', b.id, 'changes', ch,
    'before', jsonb_build_object('vehicle_id', b.vehicle_id, 'pickup_at', b.pickup_at, 'return_at', b.return_at, 'billable_days', b.billable_days,
                                 'rental_charge_cents', b.rental_charge_cents, 'subtotal_cents', b.subtotal_at_booking_cents,
                                 'hst_cents', b.hst_at_booking_cents, 'total_cents', b.total_due_at_booking_cents),
    'after', jsonb_build_object('vehicle_id', v_vehicle, 'pickup_at', v_pickup, 'return_at', v_return, 'billable_days', v_days,
                                'rental_charge_cents', v_rental, 'rate_applied', v_new ->> 'rate_applied',
                                'subtotal_cents', v_sub, 'hst_cents', v_hst, 'total_cents', v_sub + v_hst),
    'lines', (select coalesce(jsonb_agg((x.value - 'revenue_class' - 'sort_order') order by x.ord), '[]'::jsonb)
                from jsonb_array_elements(v_new -> 'lines') with ordinality x(value, ord)),
    'difference_cents', v_sub - b.subtotal_at_booking_cents, 'hst_cents', v_hst - b.hst_at_booking_cents,
    'total_difference_cents', (v_sub + v_hst) - b.total_due_at_booking_cents, 'available', v_available);
end $$;

-- A change request on a confirmed booking: by the renter (status 'requested', for staff to
-- decide) or by staff (status 'proposed', for the renter to agree to). Priced when it is made.
create or replace function app.request_booking_change(p_booking uuid, p_by uuid, p_changes jsonb, p_note text default null)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v jsonb;
  v_staff boolean := app.user_is_staff(p_by);
  v_renter boolean := app.is_booking_renter(p_booking, p_by);
  v_id uuid;
begin
  select * into b from bookings where id = p_booking for update;
  if b.id is null then raise exception 'Booking % not found', p_booking; end if;
  if p_by is null or not (v_staff or v_renter) then
    raise exception 'Only the renter of this booking, or staff, asks for a change' using errcode = '42501';
  end if;
  if exists (select 1 from booking_change_requests c where c.booking_id = p_booking and c.status in ('requested', 'proposed', 'approved')) then
    raise exception 'A change request is already open on booking %', b.booking_number using errcode = '23514';
  end if;
  v := app.preview_booking_change(p_booking, p_changes);
  if not (v ->> 'ok')::boolean then
    raise exception '%', v -> 'problems' -> 0 ->> 'message' using errcode = '23514';
  end if;
  insert into booking_change_requests (booking_id, requested_by_role, requested_by, status, note, changes, before, after, lines,
                                       difference_cents, hst_cents, total_difference_cents, priced_at, decided_by, decided_at)
  values (p_booking, case when v_renter and not v_staff then 'renter' else 'staff' end, p_by,
          case when v_renter and not v_staff then 'requested' else 'proposed' end, nullif(btrim(coalesce(p_note, '')), ''),
          v -> 'changes', v -> 'before', v -> 'after', v -> 'lines',
          (v ->> 'difference_cents')::bigint, (v ->> 'hst_cents')::bigint, (v ->> 'total_difference_cents')::bigint, now(),
          case when v_staff then p_by end, case when v_staff then now() end)
  returning id into v_id;
  perform app.log_booking_event(p_booking, 'booking_change', b.status::text, b.status::text, null, p_note, p_by, null,
    jsonb_build_object('change_request_id', v_id, 'step', case when v_renter and not v_staff then 'requested' else 'proposed' end,
                       'changes', v -> 'changes', 'total_difference_cents', (v ->> 'total_difference_cents')::bigint));
  if v_renter and not v_staff then
    insert into tasks (queue, task_type, title, detail, procedure_no, priority, booking_id, vehicle_id, renter_id, related_table, related_id)
    values ('cs', 'booking_change_requested', format('Booking %s: the customer asked for a change', b.booking_number),
            coalesce(p_note, 'Approve and price the change, or decline it with a reason.'), 1, 'normal',
            p_booking, b.vehicle_id, b.renter_id, 'booking_change_requests', v_id);
    perform app.emit_event('renter_change_request_received', 'booking_change_request', v_id,
      jsonb_build_object('booking_id', p_booking, 'booking_number', b.booking_number, 'changes', v -> 'changes', 'note', p_note,
                         'total_difference_cents', (v ->> 'total_difference_cents')::bigint),
      'renter_change_request_received:' || v_id || ':requested');
    perform app.emit_event('staff_change_request_received', 'booking_change_request', v_id,
      jsonb_build_object('booking_id', p_booking, 'booking_number', b.booking_number, 'changes', v -> 'changes', 'note', p_note,
                         'pickup_at', b.pickup_at, 'total_difference_cents', (v ->> 'total_difference_cents')::bigint),
      'staff_change_request_received:' || v_id || ':requested');
  end if;
  return v_id;
end $$;

-- Staff approve a renter's change request: priced again as of now. A change the renter asked
-- for that costs nothing more needs no further agreement from them.
create or replace function app.approve_booking_change(p_request uuid, p_by uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  c booking_change_requests;
  b bookings;
  v jsonb;
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'fleet')) then
    raise exception 'Only customer service, fleet or an Admin approves a change request' using errcode = '42501';
  end if;
  select * into c from booking_change_requests where id = p_request for update;
  if c.id is null then raise exception 'Change request % not found', p_request; end if;
  select * into b from bookings where id = c.booking_id for update;
  if c.status <> 'requested' then
    raise exception 'This change request is %: only a requested one is approved', c.status using errcode = '23514';
  end if;
  v := app.preview_booking_change(c.booking_id, c.changes);
  if not (v ->> 'ok')::boolean then
    raise exception '%', v -> 'problems' -> 0 ->> 'message' using errcode = '23514';
  end if;
  update booking_change_requests
     set status = 'approved', decided_by = p_by, decided_at = now(), before = v -> 'before', after = v -> 'after', lines = v -> 'lines',
         difference_cents = (v ->> 'difference_cents')::bigint, hst_cents = (v ->> 'hst_cents')::bigint,
         total_difference_cents = (v ->> 'total_difference_cents')::bigint, priced_at = now(),
         renter_agreed_at = case when c.requested_by_role = 'renter' and (v ->> 'total_difference_cents')::bigint <= 0 then now() end,
         agreed_by = case when c.requested_by_role = 'renter' and (v ->> 'total_difference_cents')::bigint <= 0 then c.requested_by end
   where id = p_request;
  perform app.log_booking_event(c.booking_id, 'booking_change', b.status::text, b.status::text, null, null, p_by, 'staff',
    jsonb_build_object('change_request_id', c.id, 'step', 'approved', 'total_difference_cents', (v ->> 'total_difference_cents')::bigint));
  perform app.emit_event('renter_change_request_approved', 'booking_change_request', c.id,
    jsonb_build_object('booking_id', c.booking_id, 'booking_number', b.booking_number, 'changes', c.changes,
                       'after', v -> 'after', 'total_difference_cents', (v ->> 'total_difference_cents')::bigint),
    'renter_change_request_approved:' || c.id || ':approved');
  return v || jsonb_build_object('change_request_id', c.id, 'status', 'approved');
end $$;

-- Staff decline a change request with a reason.
create or replace function app.decline_booking_change(p_request uuid, p_by uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  c booking_change_requests;
  b bookings;
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'fleet')) then
    raise exception 'Only customer service, fleet or an Admin declines a change request' using errcode = '42501';
  end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'Declining a change request needs a reason' using errcode = '22023';
  end if;
  select * into c from booking_change_requests where id = p_request for update;
  if c.id is null then raise exception 'Change request % not found', p_request; end if;
  select * into b from bookings where id = c.booking_id;
  if c.status not in ('requested', 'proposed', 'approved') then
    raise exception 'This change request is % and is no longer open', c.status using errcode = '23514';
  end if;
  update booking_change_requests set status = 'declined', decline_reason = p_reason, decided_by = p_by, decided_at = now() where id = p_request;
  perform app.log_booking_event(c.booking_id, 'booking_change', b.status::text, b.status::text, null, p_reason, p_by, 'staff',
    jsonb_build_object('change_request_id', c.id, 'step', 'declined'));
  perform app.emit_event('renter_change_request_declined', 'booking_change_request', c.id,
    jsonb_build_object('booking_id', c.booking_id, 'booking_number', b.booking_number, 'changes', c.changes, 'decline_reason', p_reason),
    'renter_change_request_declined:' || c.id || ':declined');
end $$;

-- The renter withdraws their change request (or staff withdraw a proposal).
create or replace function app.withdraw_booking_change(p_request uuid, p_by uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  c booking_change_requests;
  b bookings;
begin
  select * into c from booking_change_requests where id = p_request for update;
  if c.id is null then raise exception 'Change request % not found', p_request; end if;
  select * into b from bookings where id = c.booking_id;
  if p_by is null or not (app.is_booking_renter(c.booking_id, p_by) or app.user_is_staff(p_by)) then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if c.status not in ('requested', 'proposed', 'approved') then
    raise exception 'This change request is % and is no longer open', c.status using errcode = '23514';
  end if;
  update booking_change_requests set status = 'cancelled' where id = p_request;
  perform app.log_booking_event(c.booking_id, 'booking_change', b.status::text, b.status::text, null, null, p_by, null,
    jsonb_build_object('change_request_id', c.id, 'step', 'withdrawn'));
end $$;

-- The renter agrees to a change staff proposed, or to the price of one they asked for. An
-- Admin may record an agreement given by phone, with a note, when the change costs nothing more.
create or replace function app.agree_booking_change(p_request uuid, p_by uuid, p_ip inet default null, p_user_agent text default null,
                                                    p_phone_note text default null)
returns void language plpgsql security definer set search_path = public, app as $$
declare
  c booking_change_requests;
  b bookings;
  v_phone boolean := nullif(btrim(coalesce(p_phone_note, '')), '') is not null;
begin
  select * into c from booking_change_requests where id = p_request for update;
  if c.id is null then raise exception 'Change request % not found', p_request; end if;
  select * into b from bookings where id = c.booking_id;
  if c.status not in ('proposed', 'approved') then
    raise exception 'This change request is %: there is nothing to agree to', c.status using errcode = '23514';
  end if;
  if v_phone then
    if not app.user_is_admin(p_by) then
      raise exception 'Only an Admin records an agreement given by phone' using errcode = '42501';
    end if;
    if c.total_difference_cents > 0 then
      raise exception 'A change the renter pays for is agreed by the renter online' using errcode = '23514';
    end if;
  elsif p_by is null or not app.is_booking_renter(c.booking_id, p_by) then
    raise exception 'Only the renter of this booking agrees to a change to it' using errcode = '42501';
  end if;
  update booking_change_requests
     set status = 'approved', renter_agreed_at = now(), agreed_by = p_by, agreed_ip = p_ip, agreed_user_agent = p_user_agent,
         agreed_by_phone = v_phone, agreed_note = case when v_phone then btrim(p_phone_note) end
   where id = p_request;
  perform app.log_booking_event(c.booking_id, 'booking_change', b.status::text, b.status::text, null, p_phone_note, p_by, null,
    jsonb_build_object('change_request_id', c.id, 'step', 'agreed', 'by_phone', v_phone));
end $$;

-- Apply an approved and agreed change: under the lock on the car (both cars when it moves), the
-- price is worked out again and must be the price agreed, the money is recorded (a payment of
-- exactly the difference when the renter owes more; a refund waiting for approval when they
-- are owed), and the booking, its lines and its totals change together. The database refuses
-- the move if the car is not free.
create or replace function app.apply_booking_change(p_request uuid, p_by uuid, p_processor jsonb default null, p_amount_cents bigint default null)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  c booking_change_requests;
  b bookings;
  v jsonb;
  v_booking uuid;
  v_new_vehicle uuid;
  v_diff bigint;
  v_pay uuid;
  v_refund uuid;
  v_days integer;
  r record;
  v_set program_settings;
  v_rental bigint;
begin
  select booking_id, (changes ->> 'vehicle_id')::uuid into v_booking, v_new_vehicle from booking_change_requests where id = p_request;
  if v_booking is null then raise exception 'Change request % not found', p_request; end if;
  perform 1 from vehicles
    where id in ((select o.vehicle_id from bookings o where o.id = v_booking), v_new_vehicle) order by id for no key update;
  select * into b from bookings where id = v_booking for update;
  select * into c from booking_change_requests where id = p_request for update;
  if p_by is null or not (app.user_is_staff(p_by) or app.is_booking_renter(v_booking, p_by)) then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if c.status <> 'approved' then
    raise exception 'This change request is %: it is applied once approved', c.status using errcode = '23514';
  end if;
  if c.renter_agreed_at is null then
    raise exception 'The renter has not agreed to this change yet' using errcode = '23514';
  end if;
  v := app.preview_booking_change(v_booking, c.changes);
  if not (v ->> 'ok')::boolean then
    raise exception '%', v -> 'problems' -> 0 ->> 'message' using errcode = '23514';
  end if;
  v_diff := (v ->> 'total_difference_cents')::bigint;
  if v_diff is distinct from c.total_difference_cents then
    raise exception 'The price of this change is no longer the price agreed (% now, % agreed): approve it again', v_diff, c.total_difference_cents
      using errcode = '23514';
  end if;
  if v_diff > 0 then
    if nullif(p_processor ->> 'payment_id', '') is null or p_amount_cents is distinct from v_diff then
      raise exception 'This change needs a payment of exactly % cents', v_diff using errcode = '23514';
    end if;
    insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, payment_method_id, processed_at, created_by)
    values (b.id, b.renter_id, 'extension', 'charge', 'card', p_amount_cents, 'succeeded', b.card_on_file_id, now(), p_by)
    returning id into v_pay;
    insert into payment_processor_details (payment_id, processor, processor_payment_id, processor_charge_id, receipt_url)
    values (v_pay, coalesce(nullif(p_processor ->> 'processor', ''), 'stripe'), p_processor ->> 'payment_id', p_processor ->> 'charge_id',
            p_processor ->> 'receipt_url');
  elsif v_diff < 0 then
    insert into refunds (booking_id, payment_id, reason, amount_cents, status, requested_by, note)
    values (b.id, (select p.id from payments p where p.booking_id = b.id and p.purpose = 'booking_total' and p.kind = 'charge' and p.status = 'succeeded'
                    order by p.processed_at desc nulls last limit 1),
            'other', -v_diff, 'pending_approval', p_by, format('Change to booking %s: the new dates or car cost less', b.booking_number))
    returning id into v_refund;
    insert into tasks (queue, task_type, title, detail, procedure_no, priority, booking_id, vehicle_id, renter_id, related_table, related_id)
    values ('finance', 'change_refund', format('Booking %s: refund after a change', b.booking_number),
            format('The change lowered the price by %s cents. The refund waits for an Admin''s approval.', -v_diff), 1, 'normal',
            b.id, b.vehicle_id, b.renter_id, 'refunds', v_refund);
  end if;

  v_days := (v -> 'after' ->> 'billable_days')::integer;
  v_rental := (v -> 'after' ->> 'rental_charge_cents')::bigint;
  v_set := app.settings(app.local_date(b.booked_at));
  select * into r from public.calc_rental_charge((v -> 'after' ->> 'pickup_at')::timestamptz, v_days,
                                                 b.daily_rate_cents, b.weekend_rate_cents, b.weekly_rate_cents, b.monthly_rate_cents);
  update bookings
     set vehicle_id = (v -> 'after' ->> 'vehicle_id')::uuid, pickup_at = (v -> 'after' ->> 'pickup_at')::timestamptz,
         return_at = (v -> 'after' ->> 'return_at')::timestamptz, original_return_at = (v -> 'after' ->> 'return_at')::timestamptz,
         billable_days = v_days, km_allowance_total = km_allowance_per_day * v_days,
         rate_applied = case when booking_type = 'owner' then 'none' else r.rate_applied end, daily_days = r.daily_days, weekend_days = r.weekend_days,
         rental_charge_cents = v_rental,
         discount_cents = case when booking_type = 'non_refundable' then public.calc_bps(v_rental, v_set.non_refundable_discount_bps) else 0 end
   where id = b.id;
  perform app.sync_booking_price(b.id);
  if v_pay is not null then
    update booking_line_items set payment_id = v_pay
     where booking_id = b.id and stage = 'booking' and charged_to_renter and voided_at is null and payment_id is null;
  end if;
  if (v -> 'after' ->> 'vehicle_id')::uuid <> b.vehicle_id then
    insert into booking_vehicle_swaps (booking_id, from_vehicle_id, to_vehicle_id, reason, approved_by)
    values (b.id, b.vehicle_id, (v -> 'after' ->> 'vehicle_id')::uuid, 'Change request before pickup', c.decided_by);
  end if;
  update booking_change_requests set status = 'applied', applied_by = p_by, applied_at = now(), payment_id = v_pay, refund_id = v_refund
   where id = p_request;
  perform app.log_booking_event(b.id, 'booking_change', b.status::text, b.status::text, null, null, p_by, null,
    jsonb_build_object('change_request_id', c.id, 'step', 'applied', 'before', v -> 'before', 'after', v -> 'after',
                       'total_difference_cents', v_diff, 'payment_id', v_pay, 'refund_id', v_refund));
  return jsonb_build_object('ok', true, 'change_request_id', c.id, 'booking_id', b.id, 'status', 'applied',
                            'total_difference_cents', v_diff, 'payment_id', v_pay, 'refund_id', v_refund, 'after', v -> 'after');
end $$;

-- ================================================================ "more information needed" on a request
-- Staff ask the customer a question about a request, with a time to answer by. The booking
-- stays a request; awaiting_renter_since shows that it is waiting on the customer.
create or replace function app.ask_booking_info(p_booking uuid, p_by uuid, p_question text, p_reply_by timestamptz default null)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_reply_by timestamptz;
  v_id uuid;
begin
  if not app.user_is_staff(p_by) then
    raise exception 'Only staff ask a customer for more information' using errcode = '42501';
  end if;
  if nullif(btrim(coalesce(p_question, '')), '') is null then
    raise exception 'Write the question for the customer' using errcode = '22023';
  end if;
  select * into b from bookings where id = p_booking for update;
  if b.id is null then raise exception 'Booking % not found', p_booking; end if;
  if b.status <> 'requested' then
    raise exception 'Booking % is %: a question like this is asked on a request', b.booking_number, b.status using errcode = '23514';
  end if;
  v_reply_by := coalesce(p_reply_by, now() + make_interval(hours => (app.settings()).info_request_reply_hours));
  if v_reply_by <= now() then
    raise exception 'The time to answer by must be in the future' using errcode = '22023';
  end if;
  insert into booking_info_requests (booking_id, question, asked_by, reply_by) values (p_booking, btrim(p_question), p_by, v_reply_by)
  returning id into v_id;
  update bookings set awaiting_renter_since = coalesce(awaiting_renter_since, now()) where id = p_booking;
  insert into messages (direction, channel, subject, body, user_id, renter_id, booking_id, vehicle_id, related_table, related_id, sent_by, status)
  select 'outbound', 'portal', format('A question about your request %s', b.booking_number), btrim(p_question), rn.user_id, b.renter_id,
         p_booking, b.vehicle_id, 'booking_info_requests', v_id, p_by, 'sent'
    from renters rn where rn.id = b.renter_id;
  perform app.log_booking_event(p_booking, 'info_requested', 'requested', 'requested', null, btrim(p_question), p_by, 'staff',
    jsonb_build_object('info_request_id', v_id, 'reply_by', v_reply_by));
  perform app.emit_event('renter_request_needs_info', 'booking_info_request', v_id,
    jsonb_build_object('booking_id', p_booking, 'booking_number', b.booking_number, 'info_request', btrim(p_question), 'reply_by', v_reply_by),
    'renter_request_needs_info:' || v_id || ':asked');
  return v_id;
end $$;

-- The customer answers (or staff record the answer given by phone). The request goes back to
-- the customer service queue.
create or replace function app.reply_booking_info(p_request uuid, p_by uuid, p_reply text) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  i booking_info_requests;
  b bookings;
begin
  select * into i from booking_info_requests where id = p_request for update;
  if i.id is null then raise exception 'Question % not found', p_request; end if;
  select * into b from bookings where id = i.booking_id for update;
  if p_by is null or not (app.is_booking_renter(i.booking_id, p_by) or app.user_is_staff(p_by)) then
    raise exception 'Only the renter of this booking answers this question' using errcode = '42501';
  end if;
  if i.status <> 'open' then
    raise exception 'This question is % and no longer waits for an answer', i.status using errcode = '23514';
  end if;
  if nullif(btrim(coalesce(p_reply, '')), '') is null then
    raise exception 'Write the answer' using errcode = '22023';
  end if;
  update booking_info_requests set status = 'answered', reply = btrim(p_reply), replied_by = p_by, replied_at = now() where id = p_request;
  if not exists (select 1 from booking_info_requests x where x.booking_id = i.booking_id and x.status = 'open') then
    update bookings set awaiting_renter_since = null where id = i.booking_id;
  end if;
  insert into messages (direction, channel, subject, body, user_id, renter_id, booking_id, vehicle_id, related_table, related_id, status)
  select 'inbound', 'portal', format('Answer about request %s', b.booking_number), btrim(p_reply), rn.user_id, b.renter_id,
         b.id, b.vehicle_id, 'booking_info_requests', i.id, 'received'
    from renters rn where rn.id = b.renter_id;
  insert into tasks (queue, task_type, title, detail, procedure_no, priority, booking_id, vehicle_id, renter_id, related_table, related_id)
  values ('cs', 'info_reply_received', format('Request %s: the customer answered', b.booking_number), btrim(p_reply), 1, 'high',
          b.id, b.vehicle_id, b.renter_id, 'booking_info_requests', i.id);
  perform app.log_booking_event(i.booking_id, 'info_replied', b.status::text, b.status::text, null, btrim(p_reply), p_by, null,
    jsonb_build_object('info_request_id', i.id));
end $$;

-- Staff close a question that no longer needs an answer.
create or replace function app.close_booking_info(p_request uuid, p_by uuid, p_reason text default null) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  i booking_info_requests;
begin
  if not app.user_is_staff(p_by) then
    raise exception 'Only staff close a question' using errcode = '42501';
  end if;
  select * into i from booking_info_requests where id = p_request for update;
  if i.id is null then raise exception 'Question % not found', p_request; end if;
  if i.status <> 'open' then return; end if;
  update booking_info_requests set status = 'closed', closed_reason = coalesce(nullif(btrim(coalesce(p_reason, '')), ''), 'Closed by staff') where id = p_request;
  if not exists (select 1 from booking_info_requests x where x.booking_id = i.booking_id and x.status = 'open') then
    update bookings set awaiting_renter_since = null where id = i.booking_id;
  end if;
end $$;

-- ================================================================ identity and coverage documents
-- Is a booking ready for the car to be handed over? One answer per booking, for the renter's
-- checklist, the staff screens and the handover step. Read only.
create or replace function app.booking_readiness(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  v_owner boolean;
  v_drivers jsonb;
  v_verified boolean;
  v_accepted boolean;
  v_coverage boolean;
  v_dep_taken boolean;
  v_deposit boolean;
  v_agreement boolean;
  v_report boolean;
  v_missing text[] := '{}';
begin
  select * into b from bookings where id = p_booking;
  if b.id is null then raise exception 'Booking % not found', p_booking; end if;
  v_owner := b.booking_type = 'owner';
  select coalesce(jsonb_agg(jsonb_build_object(
           'booking_driver_id', d.id, 'driver_id', d.driver_id, 'role', d.role, 'name', d.full_name,
           'identity_verified', d.identity_verified_on is not null, 'identity_verified_on', d.identity_verified_on,
           'accepted', d.role = 'renter' or d.accepted_at is not null,
           'uploads', (select coalesce(jsonb_object_agg(u.kind, u.status), '{}'::jsonb) from verification_uploads u
                        where u.booking_id = p_booking and u.driver_id = d.driver_id and u.status in ('submitted', 'approved', 'rejected')
                          and not exists (select 1 from verification_uploads n where n.booking_id = u.booking_id and n.driver_id = u.driver_id
                                             and n.kind = u.kind and n.uploaded_at > u.uploaded_at)))
           order by d.role desc, d.full_name, d.id), '[]'::jsonb),
         coalesce(bool_and(d.identity_verified_on is not null), false) and coalesce(bool_or(d.role = 'renter'), false),
         coalesce(bool_and(d.role = 'renter' or d.accepted_at is not null), true)
    into v_drivers, v_verified, v_accepted
    from booking_drivers d where d.booking_id = p_booking;
  v_coverage := v_owner or (b.coverage_confirmed_at is not null
                            and exists (select 1 from coverage_proofs c where c.booking_id = p_booking and c.status = 'confirmed'));
  v_dep_taken := exists (select 1 from deposits d where d.booking_id = p_booking and d.status in ('held', 'captured'));
  v_deposit := v_owner or b.deposit_waived_at is not null or v_dep_taken;
  v_agreement := exists (select 1 from signature_requests s where s.id = b.signature_request_id and s.status = 'completed');
  v_report := exists (select 1 from condition_reports c where c.booking_id = p_booking and c.kind = 'pickup');
  if not v_verified then v_missing := v_missing || 'identity'::text; end if;
  if not v_coverage then v_missing := v_missing || 'coverage'::text; end if;
  if not v_accepted then v_missing := v_missing || 'additional_driver_acceptance'::text; end if;
  if not v_deposit then v_missing := v_missing || 'deposit'::text; end if;
  if not b.blocks_calendar then v_missing := v_missing || 'calendar_switch'::text; end if;
  if not v_agreement then v_missing := v_missing || 'agreement'::text; end if;
  if not v_report then v_missing := v_missing || 'pickup_condition_report'::text; end if;
  return jsonb_build_object(
    'booking_id', b.id, 'status', b.status, 'drivers', v_drivers,
    'all_drivers_verified', v_verified, 'coverage_confirmed', v_coverage,
    'identity_and_coverage_confirmed', v_verified and v_coverage,
    'additional_drivers_accepted', v_accepted,
    'deposit_taken', v_dep_taken, 'deposit_waived', b.deposit_waived_at is not null, 'deposit_ok', v_deposit,
    'blocks_calendar', b.blocks_calendar, 'agreement_completed', v_agreement, 'pickup_condition_report', v_report,
    'ready_for_handover', b.status = 'confirmed' and cardinality(v_missing) = 0, 'missing', to_jsonb(v_missing));
end $$;

-- Register a file the renter (or a driver through their link, or staff for them) uploaded to
-- private storage: a licence front, a licence back, a selfie, or the proof of coverage. The
-- server has already checked the file and passes where it is; nothing but its key is stored.
--   * Licence images and the selfie carry the 90-day retention class and a purge date that
--     follows the end of the rental (program_settings.retention_id_face_days).
--   * A new upload of the same kind replaces the earlier one (which is kept, marked replaced).
--   * p_details, for the proof of coverage: {coverage_option (1 or 2), insurer_name,
--     policy_number, policy_expiry, card_issuer, card_last4}.
create or replace function app.register_verification_upload(p_booking uuid, p_by uuid, p_kind text, p_driver uuid, p_storage_path text,
                                                            p_sha256 text default null, p_mime_type text default null,
                                                            p_details jsonb default null, p_storage_bucket text default null)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_set program_settings := app.settings();
  v_id_kind boolean := p_kind in ('licence_front', 'licence_back', 'selfie');
  d jsonb := coalesce(p_details, '{}'::jsonb);
  v_doc uuid;
  v_iv uuid;
  v_cp uuid;
  v_option integer;
  v_purge timestamptz;
  v_id uuid;
  v_name text;
begin
  select * into b from bookings where id = p_booking for update;
  if b.id is null then raise exception 'Booking % not found', p_booking; end if;
  if p_kind is null or p_kind not in ('licence_front', 'licence_back', 'selfie', 'coverage_proof') then
    raise exception 'Unknown kind of upload "%"', p_kind using errcode = '22023';
  end if;
  if p_by is not null and not (app.is_booking_renter(p_booking, p_by) or app.user_is_staff(p_by)
       or exists (select 1 from drivers x where x.id = p_driver and x.user_id = p_by)
       or exists (select 1 from staff_profiles sp join users u on u.id = sp.user_id
                   where sp.user_id = p_by and sp.staff_type = 'field' and sp.is_active and u.status = 'active')) then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if b.status not in ('pending_payment', 'confirmed') then
    raise exception 'Booking % is %: documents are uploaded once the offer is approved', b.booking_number, b.status using errcode = '23514';
  end if;
  if nullif(btrim(coalesce(p_storage_path, '')), '') is null then
    raise exception 'An upload needs the key of its file in private storage' using errcode = '22023';
  end if;
  if v_id_kind then
    select x.full_name into v_name from booking_drivers x where x.booking_id = p_booking and x.driver_id = p_driver;
    if v_name is null then raise exception 'That driver is not on this booking' using errcode = '23514'; end if;
    v_purge := greatest(b.return_at, now()) + make_interval(days => v_set.retention_id_face_days);
  elsif p_driver is not null then
    raise exception 'The proof of coverage belongs to the booking, not to one driver' using errcode = '22023';
  elsif b.booking_type = 'owner' then
    raise exception 'An Owner Booking needs no Coverage Option' using errcode = '23514';
  end if;

  insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256, retention, purge_after, uploaded_by, renter_id, booking_id)
  values (case p_kind when 'licence_front' then 'id_front' when 'licence_back' then 'id_back' when 'selfie' then 'face_photo' else 'coverage_proof' end::document_kind,
          case p_kind when 'licence_front' then 'Licence, front: ' || v_name when 'licence_back' then 'Licence, back: ' || v_name
                      when 'selfie' then 'Face photo: ' || v_name else 'Proof of coverage, booking ' || b.booking_number end,
          coalesce(p_storage_bucket, case when v_id_kind then 'identity' else 'agreements' end), p_storage_path, p_mime_type,
          lower(nullif(btrim(coalesce(p_sha256, '')), '')), case when v_id_kind then 'id_face_90d' else 'records_7y' end::retention_class,
          v_purge, p_by, b.renter_id, p_booking)
  returning id into v_doc;

  update verification_uploads set status = 'replaced'
   where booking_id = p_booking and driver_id is not distinct from p_driver and kind = p_kind and status in ('submitted', 'approved');

  if v_id_kind then
    -- one staff review per driver and booking, reopened by a new upload
    select iv.id into v_iv from identity_verifications iv
     where iv.driver_id = p_driver and iv.booking_id = p_booking and iv.method = 'staff_review' and iv.purged_at is null
     order by iv.created_at desc limit 1;
    if v_iv is null then
      insert into identity_verifications (driver_id, booking_id, method, status, purge_after)
      values (p_driver, p_booking, 'staff_review', 'pending', v_purge) returning id into v_iv;
    end if;
    update identity_verifications
       set status = 'pending', failure_reason = null, verified_by = null, verified_at = null, purge_after = v_purge,
           id_front_document_id = case when p_kind = 'licence_front' then v_doc else id_front_document_id end,
           id_back_document_id = case when p_kind = 'licence_back' then v_doc else id_back_document_id end,
           face_document_id = case when p_kind = 'selfie' then v_doc else face_document_id end
     where id = v_iv;
    update booking_drivers set identity_verified_on = null, identity_method = null where booking_id = p_booking and driver_id = p_driver;
    update drivers set identity_status = 'pending' where id = p_driver and identity_status <> 'verified';
  else
    v_option := coalesce((d ->> 'coverage_option')::integer, b.coverage_option);
    if v_option is null or v_option not in (1, 2) then
      raise exception 'Proof is uploaded for coverage option 1 (own auto policy) or 2 (credit card coverage)' using errcode = '22023';
    end if;
    if v_option = 1 and (d ->> 'policy_expiry') is not null and (d ->> 'policy_expiry')::date < app.local_date(b.return_at) then
      raise exception 'The policy must run to the return date or later' using errcode = '23514';
    end if;
    if v_option = 2 and (d ->> 'card_last4') is not null and b.card_on_file_id is not null
       and (d ->> 'card_last4') is distinct from (select pm.card_last4 from payment_methods pm where pm.id = b.card_on_file_id) then
      raise exception 'Credit card coverage must be on the card that pays for the rental (the Card on File)' using errcode = '23514';
    end if;
    select c.id into v_cp from coverage_proofs c where c.booking_id = p_booking and c.status = 'submitted' order by c.created_at desc limit 1;
    if v_cp is null then
      insert into coverage_proofs (booking_id, coverage_option, status, insurer_name, policy_number, policy_expiry, card_issuer, card_last4,
                                   proof_document_id)
      values (p_booking, v_option, 'submitted', d ->> 'insurer_name', d ->> 'policy_number', (d ->> 'policy_expiry')::date,
              d ->> 'card_issuer', d ->> 'card_last4', v_doc)
      returning id into v_cp;
    else
      update coverage_proofs
         set coverage_option = v_option, insurer_name = d ->> 'insurer_name', policy_number = d ->> 'policy_number',
             policy_expiry = (d ->> 'policy_expiry')::date, card_issuer = d ->> 'card_issuer', card_last4 = d ->> 'card_last4',
             proof_document_id = v_doc
       where id = v_cp;
    end if;
  end if;

  insert into verification_uploads (booking_id, driver_id, kind, document_id, identity_verification_id, coverage_proof_id, uploaded_by)
  values (p_booking, p_driver, p_kind, v_doc, v_iv, v_cp, p_by)
  returning id into v_id;

  -- one review task per booking, due before pickup
  if not exists (select 1 from tasks t where t.booking_id = p_booking and t.task_type = 'verify_renter' and t.status in ('open', 'in_progress', 'waiting')) then
    insert into tasks (queue, task_type, title, detail, procedure_no, priority, due_at, booking_id, vehicle_id, renter_id)
    values ('cs', 'verify_renter', format('Booking %s: documents to review', b.booking_number),
            'Review each licence image, selfie and proof of coverage, and approve or reject each with a reason.', 2, 'normal',
            greatest(b.pickup_at - make_interval(hours => v_set.verification_due_hours_before_pickup),
                     now() + make_interval(hours => v_set.verification_review_hours)),
            p_booking, b.vehicle_id, b.renter_id);
  end if;
  -- ready for review: the proof of coverage at once; a driver's identity once all three images are in
  if not v_id_kind or (select count(distinct u.kind) from verification_uploads u
                        where u.booking_id = p_booking and u.driver_id = p_driver and u.status in ('submitted', 'approved')) = 3 then
    perform app.emit_event('staff_identity_review', 'booking', p_booking,
      jsonb_build_object('booking_id', p_booking, 'booking_number', b.booking_number, 'kind', case when v_id_kind then 'identity' else 'coverage' end,
                         'driver_id', p_driver, 'driver_name', v_name, 'pickup_at', b.pickup_at),
      'staff_identity_review:' || p_booking || ':' || v_id);
  end if;
  return v_id;
end $$;

-- Customer service (or an Admin) approves or rejects one upload; a rejection needs its reason.
--   * A driver is verified once the licence front, the licence back and the selfie are all
--     approved: the identity check is marked verified and the driver's row on the booking
--     gets the method and the date.
--   * An approved proof of coverage confirms the booking's Coverage Option.
-- Returns the booking's roll-up (app.booking_readiness).
create or replace function app.review_verification_upload(p_upload uuid, p_by uuid, p_approve boolean, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  u verification_uploads;
  b bookings;
  cp coverage_proofs;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_ready jsonb;
  v_holder boolean;
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs')) then
    raise exception 'Only customer service or an Admin reviews identity and coverage documents' using errcode = '42501';
  end if;
  select * into u from verification_uploads where id = p_upload for update;
  if u.id is null then raise exception 'Upload % not found', p_upload; end if;
  select * into b from bookings where id = u.booking_id for update;
  if u.status <> 'submitted' then
    raise exception 'This upload is % and is not waiting for review', u.status using errcode = '23514';
  end if;
  if p_approve is null then raise exception 'Approve or reject' using errcode = '22023'; end if;
  if not p_approve and v_reason is null then
    raise exception 'Rejecting a document needs a reason the customer can act on' using errcode = '22023';
  end if;
  update verification_uploads
     set status = case when p_approve then 'approved' else 'rejected' end, reject_reason = case when not p_approve then v_reason end,
         reviewed_by = p_by, reviewed_at = now()
   where id = p_upload;

  if u.kind = 'coverage_proof' then
    select * into cp from coverage_proofs where id = u.coverage_proof_id for update;
    if p_approve then
      if (cp.coverage_option = 1 and (cp.insurer_name is null or cp.policy_number is null or cp.policy_expiry is null))
         or (cp.coverage_option = 2 and (cp.card_issuer is null or cp.card_last4 is null)) then
        raise exception 'The proof cannot be confirmed without its details: insurer, policy number and expiry for option 1; card issuer and last four digits for option 2'
          using errcode = '23514';
      end if;
      update coverage_proofs set status = 'confirmed', confirmed_by = p_by, confirmed_at = now(), covers_vehicle_and_drivers = true,
             rejection_reason = null where id = cp.id;
      update bookings set coverage_option = cp.coverage_option, coverage_confirmed_at = now() where id = b.id;
    else
      update coverage_proofs set status = 'rejected', rejection_reason = v_reason where id = cp.id;
    end if;
  elsif p_approve then
    if (select count(distinct x.kind) from verification_uploads x
         where x.booking_id = u.booking_id and x.driver_id = u.driver_id and x.status = 'approved') = 3 then
      update identity_verifications
         set status = 'verified', verified_by = p_by, verified_at = now(), failure_reason = null,
             checks = jsonb_build_object('licence_front', true, 'licence_back', true, 'selfie', true)
       where id = u.identity_verification_id;
      update booking_drivers set identity_verification_id = u.identity_verification_id, identity_method = 'staff_review',
             identity_verified_on = app.today()
       where booking_id = u.booking_id and driver_id = u.driver_id;
      update drivers set identity_status = 'verified' where id = u.driver_id returning is_account_holder into v_holder;
      if v_holder then
        update renters set identity_status = 'verified' where id = b.renter_id;
      end if;
    end if;
  else
    update identity_verifications set status = 'failed', failure_reason = v_reason where id = u.identity_verification_id;
    update booking_drivers set identity_verified_on = null, identity_method = null where booking_id = u.booking_id and driver_id = u.driver_id;
    update drivers set identity_status = 'failed' where id = u.driver_id and identity_status <> 'verified';
  end if;

  perform app.log_booking_event(u.booking_id, 'verification', b.status::text, b.status::text, null, v_reason, p_by, 'staff',
    jsonb_build_object('upload_id', u.id, 'kind', u.kind, 'driver_id', u.driver_id, 'decision', case when p_approve then 'approved' else 'rejected' end));
  v_ready := app.booking_readiness(u.booking_id);
  if not p_approve then
    perform app.emit_event('renter_identity_rejected', 'booking', u.booking_id,
      jsonb_build_object('booking_id', u.booking_id, 'booking_number', b.booking_number, 'kind', u.kind, 'driver_id', u.driver_id,
                         'driver_name', (select x.full_name from booking_drivers x where x.booking_id = u.booking_id and x.driver_id = u.driver_id),
                         'reject_reason', v_reason),
      'renter_identity_rejected:' || u.booking_id || ':' || u.id);
  elsif (v_ready ->> 'identity_and_coverage_confirmed')::boolean then
    perform app.emit_event('renter_identity_approved', 'booking', u.booking_id,
      jsonb_build_object('booking_id', u.booking_id, 'booking_number', b.booking_number, 'pickup_at', b.pickup_at),
      'renter_identity_approved:' || u.booking_id || ':verified');
  end if;
  return v_ready;
end $$;

-- ================================================================ row-level security
do $$
declare
  t text;
begin
  foreach t in array array['rental_agreements', 'rental_agreement_signers', 'webhook_events', 'booking_change_requests',
                           'booking_info_requests', 'verification_uploads'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy admin_all on public.%I for all to authenticated using (app.is_admin()) with check (app.is_admin())', t);
  end loop;
end $$;
alter table app.rate_limit_hits enable row level security;
create policy admin_all on app.rate_limit_hits for all to authenticated using (app.is_admin()) with check (app.is_admin());

-- Every one of these tables is written by the server's functions only. What each role reads
-- follows docs/permissions.md: a renter their own; assistants what their work on bookings needs.
-- rental agreements: like the booking they belong to
create policy renter_read on rental_agreements for select to authenticated using (app.is_my_booking(booking_id));
create policy va_read on rental_agreements for select to authenticated using (app.va_has('cs', 'finance', 'fleet'));
-- signers (names and email addresses of drivers): the renter of the booking, the signer, customer service
create policy renter_read on rental_agreement_signers for select to authenticated
  using (user_id = app.uid() or exists (select 1 from rental_agreements a where a.id = agreement_id and app.is_my_booking(a.booking_id)));
create policy cs_read on rental_agreement_signers for select to authenticated using (app.va_has('cs'));
-- webhook_events: processor traffic, Admin only (no further policy)
-- change requests: the renter's own; the assistants who work on bookings
create policy renter_read on booking_change_requests for select to authenticated using (app.is_my_booking(booking_id));
create policy va_read on booking_change_requests for select to authenticated using (app.va_has('cs', 'finance', 'fleet'));
-- questions on a request: the renter's own; every assistant (sales works on requests too)
create policy renter_read on booking_info_requests for select to authenticated using (app.is_my_booking(booking_id));
create policy va_read on booking_info_requests for select to authenticated using (app.is_va());
-- identity and coverage uploads: the renter's own; customer service while the renter is in their working window
create policy renter_read on verification_uploads for select to authenticated using (app.is_my_booking(booking_id));
create policy cs_read on verification_uploads for select to authenticated
  using (app.va_has('cs') and exists (select 1 from bookings b where b.id = booking_id and app.va_sees_renter(b.renter_id)));

-- ================================================================ browser access: wrappers in the public schema
-- The API exposes the public schema only. Three kinds of wrapper, each stating why it is an
-- invoker or a definer function:
--
-- (a) For anyone, the anonymous visitor included. SECURITY INVOKER: each only passes the call
--     on to an app function that the visitor may already execute and that is itself written to
--     be safe for the public (it answers for listed cars only and returns no person, owner,
--     VIN, plate or reason).
create or replace function public.public_vehicle_calendar(p_vehicle uuid, p_from date, p_to date)
returns table (unavailable_from timestamptz, unavailable_to timestamptz, first_date date, last_date date)
language sql stable security invoker set search_path = public, app as $$
  select * from app.public_vehicle_calendar(p_vehicle, p_from, p_to)
$$;

create or replace function public.public_reviews(p_vehicle uuid default null, p_limit integer default 20, p_offset integer default 0)
returns table (review_id uuid, vehicle_id uuid, vehicle_label text, rating smallint, title text, body text,
               reviewer_first_name text, review_month date, staff_reply text)
language sql stable security invoker set search_path = public, app as $$
  select * from app.public_reviews(p_vehicle, p_limit, p_offset)
$$;

create or replace function public.vehicle_is_available(p_vehicle uuid, p_from timestamptz, p_to timestamptz) returns boolean
language sql stable security invoker set search_path = public, app as $$
  select app.vehicle_is_available(p_vehicle, p_from, p_to)
$$;

create or replace function public.quote_booking(p_vehicle uuid, p_pickup timestamptz, p_return timestamptz, p_options jsonb default '{}'::jsonb)
returns jsonb language sql security invoker set search_path = public, app as $$
  select app.quote_booking(p_vehicle, p_pickup, p_return, p_options)
$$;

create or replace function public.search_available(p_pickup timestamptz, p_return timestamptz, p_filters jsonb default '{}'::jsonb)
returns table (vehicle_id uuid, slug text, vehicle_year smallint, make text, model text, vehicle_class text, seats smallint,
               transmission text, fuel text, allows_18_to_20 boolean, daily_rate_cents bigint, billable_days integer,
               rental_charge_cents bigint, subtotal_cents bigint, hst_cents bigint, total_cents bigint, deposit_cents bigint)
language sql security invoker set search_path = public, app as $$
  select * from app.search_available(p_pickup, p_return, p_filters)
$$;

-- (b) For a signed-in renter, about their own booking, read only. SECURITY DEFINER because the
--     app functions behind them read tables a renter has no access to (the bookings table
--     itself) and are closed to browser sessions; each wrapper first checks that the booking is
--     the caller's own (app.is_my_booking), and none of them writes anything.
create or replace function app.assert_my_booking(p_booking uuid) returns void
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not coalesce(app.is_my_booking(p_booking), false) then
    raise exception 'This is not your booking' using errcode = '42501';
  end if;
end $$;

create or replace function public.my_cancellation_preview(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_my_booking(p_booking);
  return app.preview_cancellation(p_booking);
end $$;

create or replace function public.my_extension_preview(p_booking uuid, p_new_return timestamptz) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_my_booking(p_booking);
  -- the renter sees the price and each line, not which part belongs to whom
  return (select v || jsonb_build_object('lines', (select coalesce(jsonb_agg((x.value - 'revenue_class' - 'sort_order') order by x.ord), '[]'::jsonb)
                                                    from jsonb_array_elements(coalesce(v -> 'lines', '[]'::jsonb)) with ordinality x(value, ord)))
            from app.preview_extension(p_booking, p_new_return) v);
end $$;

create or replace function public.my_booking_change_preview(p_booking uuid, p_changes jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_my_booking(p_booking);
  return app.preview_booking_change(p_booking, p_changes);
end $$;

create or replace function public.my_booking_readiness(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_my_booking(p_booking);
  return app.booking_readiness(p_booking);
end $$;

create or replace function public.my_promo_code_problem(p_code text, p_booking uuid) returns text
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_my_booking(p_booking);
  return app.promo_code_problem(p_code, app.my_renter_id(), p_booking);
end $$;

-- (c) For the server, acting for a visitor or a signed-in renter. SECURITY INVOKER, executable
--     by the service role only. These change a booking, and the database refuses such changes
--     from any browser session whatever function makes them (the column and approval guards of
--     migrations 0012 and 0016 look at the session, not at the function), so the server makes
--     them after its own checks: the bot check and the visitor's network address for a request,
--     the signed-in renter for the rest. Each renter action checks that p_by is the renter of
--     the booking, so these wrappers cannot be used to act as staff.
create or replace function public.submit_booking_request(p_request jsonb, p_ip inet default null, p_user_agent text default null,
                                                         p_user uuid default null)
returns jsonb language sql security invoker set search_path = public, app as $$
  select app.submit_booking_request(p_request, p_ip, p_user_agent, p_user)
$$;

create or replace function app.assert_booking_renter(p_booking uuid, p_by uuid) returns void
language plpgsql stable security definer set search_path = public, app as $$
begin
  if p_by is null or not coalesce(app.is_booking_renter(p_booking, p_by), false) then
    raise exception 'This action is for the renter of the booking' using errcode = '42501';
  end if;
end $$;

create or replace function public.renter_approve_offer(p_booking uuid, p_version integer, p_by uuid) returns void
language plpgsql security invoker set search_path = public, app as $$
begin
  perform app.assert_booking_renter(p_booking, p_by);
  perform app.approve_offer(p_booking, p_version, p_by);
end $$;

create or replace function public.renter_request_offer_change(p_booking uuid, p_by uuid, p_note text) returns void
language plpgsql security invoker set search_path = public, app as $$
begin
  perform app.assert_booking_renter(p_booking, p_by);
  perform app.request_offer_change(p_booking, p_by, p_note);
end $$;

create or replace function public.renter_withdraw_request(p_booking uuid, p_by uuid, p_note text default null) returns void
language plpgsql security invoker set search_path = public, app as $$
begin
  perform app.assert_booking_renter(p_booking, p_by);
  perform app.decline_booking_request(p_booking, p_by, p_note);
end $$;

create or replace function public.renter_cancel_booking(p_booking uuid, p_by uuid, p_note text default null) returns jsonb
language plpgsql security invoker set search_path = public, app as $$
begin
  perform app.assert_booking_renter(p_booking, p_by);
  return app.cancel_booking(p_booking, p_by, 'renter_request', p_note, 'portal');
end $$;

create or replace function public.renter_request_extension(p_booking uuid, p_by uuid, p_new_return timestamptz, p_note text default null) returns uuid
language plpgsql security invoker set search_path = public, app as $$
begin
  perform app.assert_booking_renter(p_booking, p_by);
  return app.request_extension(p_booking, p_by, p_new_return, p_note);
end $$;

create or replace function public.renter_request_booking_change(p_booking uuid, p_by uuid, p_changes jsonb, p_note text default null) returns uuid
language plpgsql security invoker set search_path = public, app as $$
begin
  perform app.assert_booking_renter(p_booking, p_by);
  return app.request_booking_change(p_booking, p_by, p_changes, p_note);
end $$;

create or replace function public.renter_agree_booking_change(p_request uuid, p_by uuid, p_ip inet default null, p_user_agent text default null) returns void
language plpgsql security invoker set search_path = public, app as $$
begin
  perform app.assert_booking_renter((select c.booking_id from booking_change_requests c where c.id = p_request), p_by);
  perform app.agree_booking_change(p_request, p_by, p_ip, p_user_agent);
end $$;

create or replace function public.renter_withdraw_booking_change(p_request uuid, p_by uuid) returns void
language plpgsql security invoker set search_path = public, app as $$
begin
  perform app.assert_booking_renter((select c.booking_id from booking_change_requests c where c.id = p_request), p_by);
  perform app.withdraw_booking_change(p_request, p_by);
end $$;

create or replace function public.renter_reply_booking_info(p_request uuid, p_by uuid, p_reply text) returns void
language plpgsql security invoker set search_path = public, app as $$
begin
  perform app.assert_booking_renter((select i.booking_id from booking_info_requests i where i.id = p_request), p_by);
  perform app.reply_booking_info(p_request, p_by, p_reply);
end $$;

-- ================================================================ privileges
revoke all on rental_agreements, rental_agreement_signers, webhook_events, booking_change_requests, booking_info_requests,
  verification_uploads from anon, authenticated;
-- written by the server only; read under the policies above
grant select on rental_agreements, rental_agreement_signers, webhook_events, booking_change_requests, booking_info_requests,
  verification_uploads to authenticated;
grant all on rental_agreements, rental_agreement_signers, webhook_events, booking_change_requests, booking_info_requests,
  verification_uploads to service_role;
revoke all on app.rate_limit_hits from public, anon, authenticated;
grant select on app.rate_limit_hits to authenticated;
grant all on app.rate_limit_hits to service_role;
grant usage on sequence rental_agreement_number_seq to service_role;

-- Functions: closed to everyone, then opened one by one. Everything in this migration that
-- changes anything is for the server alone.
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array[
              'guard_signature_record', 'rate_limit', 'rate_limit_purge', 'request_ip', 'public_rate_check', 'session_aal',
              'staff_two_step_ok', 'user_va_has', 'age_on', 'age_band', 'fee_term', 'price_line', 'price_lines', 'booking_price_spec',
              'put_price_line', 'sync_booking_price', 'reprice_booking', 'price_quote', 'quote_booking', 'search_available',
              'submit_booking_request', 'void_rental_agreements', 'open_rental_agreement', 'record_signature',
              'complete_signature_request', 'attach_signed_agreement', 'webhook_event_claim', 'webhook_event_finish',
              'save_card_on_file', 'push_back_booking', 'refuse_confirmation', 'finalize_booking', 'record_booking_payment',
              'confirm_unpaid_booking', 'booking_payment_capture_failed', 'booking_app_before', 'booking_app_after', 'waive_deposit',
              'booking_paid_cents', 'preview_cancellation', 'cancel_booking', 'preview_extension', 'request_extension',
              'approve_extension', 'decline_extension', 'confirm_extension_payment', 'lapse_extensions', 'preview_booking_change',
              'request_booking_change', 'approve_booking_change', 'decline_booking_change', 'withdraw_booking_change',
              'agree_booking_change', 'apply_booking_change', 'ask_booking_info', 'reply_booking_info', 'close_booking_info',
              'booking_readiness', 'register_verification_upload', 'review_verification_upload', 'assert_my_booking',
              'assert_booking_renter']))
        or (n.nspname = 'public' and p.proname = any (array[
              'public_vehicle_calendar', 'public_reviews', 'vehicle_is_available', 'quote_booking', 'search_available',
              'my_cancellation_preview', 'my_extension_preview', 'my_booking_change_preview', 'my_booking_readiness',
              'my_promo_code_problem', 'submit_booking_request', 'renter_approve_offer', 'renter_request_offer_change',
              'renter_withdraw_request', 'renter_cancel_booking', 'renter_request_extension', 'renter_request_booking_change',
              'renter_agree_booking_change', 'renter_withdraw_booking_change', 'renter_reply_booking_info']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
  end loop;
end $$;
grant execute on all functions in schema app to service_role;

-- (a) anyone: the price of a listed car, and which listed cars are free
grant execute on function app.quote_booking(uuid, timestamptz, timestamptz, jsonb),
  app.search_available(timestamptz, timestamptz, jsonb) to anon, authenticated;
grant execute on function public.public_vehicle_calendar(uuid, date, date), public.public_reviews(uuid, integer, integer),
  public.vehicle_is_available(uuid, timestamptz, timestamptz), public.quote_booking(uuid, timestamptz, timestamptz, jsonb),
  public.search_available(timestamptz, timestamptz, jsonb) to anon, authenticated, service_role;
-- (b) a signed-in renter, about their own booking, read only
grant execute on function public.my_cancellation_preview(uuid), public.my_extension_preview(uuid, timestamptz),
  public.my_booking_change_preview(uuid, jsonb), public.my_booking_readiness(uuid), public.my_promo_code_problem(text, uuid)
  to authenticated, service_role;
-- (c) the server
grant execute on function public.submit_booking_request(jsonb, inet, text, uuid), public.renter_approve_offer(uuid, integer, uuid),
  public.renter_request_offer_change(uuid, uuid, text), public.renter_withdraw_request(uuid, uuid, text),
  public.renter_cancel_booking(uuid, uuid, text), public.renter_request_extension(uuid, uuid, timestamptz, text),
  public.renter_request_booking_change(uuid, uuid, jsonb, text), public.renter_agree_booking_change(uuid, uuid, inet, text),
  public.renter_withdraw_booking_change(uuid, uuid), public.renter_reply_booking_info(uuid, uuid, text) to service_role;
-- the session's assurance level is not a secret from the session itself
grant execute on function app.session_aal() to anon, authenticated;

-- ================================================================ audit
do $$ begin perform app.attach_audit(); end $$;
