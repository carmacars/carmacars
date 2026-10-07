-- 0016_request_to_book.sql
-- The booking model changes from "hold, pay, confirmed" to "request to book":
--
--   requested -> offered -> pending_payment -> confirmed -> on_rent -> returned -> closed
--
--   * A renter asks (requested). No payment and no card are taken. A request never blocks the
--     calendar, and several requests for the same car and dates may coexist.
--   * Staff adjust the booking and send an offer (offered). Every offer sent is kept as a
--     version in booking_offers.
--   * The renter approves the current version (pending_payment), signs and pays (confirmed).
--     Only a confirmed or on rent booking with blocks_calendar = true blocks the car.
--   * Confirming a booking moves every other offered or pending_payment booking on the same
--     car and dates back to requested, so staff can offer another car.
--   * Offers expire (24 hours unless set otherwise); an expired offer goes back to requested.
--
-- Also here: the calendar blocking switch, billing a booking to an insurance company, insurer
-- invoices, availability and the two calendars, promo codes and reviews.
-- Notes, decisions and assumptions: docs/changes/0016_request_to_book.md.
--
-- A NOTE ON THE TWO NEW STATUS VALUES. PostgreSQL does not let a value added to an enum be used
-- in the transaction that adds it, and a migration is one transaction. So nothing in this file
-- that is checked when it is created (a view, a policy, an index, an SQL-language function, a
-- column default) names 'requested' or 'offered' as a booking_status. Those places compare
-- status::text instead. The plpgsql functions are only checked when they first run, which is
-- after this migration has been committed, so they use the values in the ordinary way.

alter type booking_status add value if not exists 'requested' before 'tentative';  -- the renter has asked; staff are reviewing
alter type booking_status add value if not exists 'offered' before 'tentative';    -- an offer is with the renter
-- 'tentative' (the old 2-hour hold) stays in the type because a value cannot be removed.
-- No flow in this migration puts a booking into it.

-- ---------------------------------------------------------------- settings
alter table program_settings
  add column offer_expiry_hours integer not null default 24 check (offer_expiry_hours between 1 and 720);
comment on column program_settings.offer_expiry_hours is 'How long an offer stays open unless the offer itself says otherwise.';
comment on column program_settings.tentative_hold_minutes is 'No longer used: the 2-hour hold was replaced by request to book in migration 0016.';

-- ---------------------------------------------------------------- insurers
-- An insurance company that pays for a replacement rental. Never the fleet insurer and never a
-- coverage provider: those are not billed by CarmaCars.
create table insurers (
  id                   uuid primary key default gen_random_uuid(),
  name                 text not null,
  billing_contact_name text,
  billing_email        text,
  billing_phone        text,
  billing_address      text,
  notes                text,
  is_active            boolean not null default true,
  created_by           uuid references users (id),
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);
create unique index insurers_name_key on insurers (lower(name));
create trigger insurers_updated before update on insurers for each row execute function app.set_updated_at();

-- ---------------------------------------------------------------- promo codes
create table promo_codes (
  id              uuid primary key default gen_random_uuid(),
  code            text not null check (code = upper(btrim(code)) and length(code) between 3 and 40),
  description     text,
  -- one of the two: a percentage of the rental charge, or a fixed amount off it
  percent_bps     integer check (percent_bps between 1 and 10000),
  amount_cents    bigint check (amount_cents > 0),
  valid_from      timestamptz not null default now(),
  valid_until     timestamptz,
  max_uses        integer check (max_uses > 0),        -- null = no limit
  once_per_renter boolean not null default true,
  renter_id       uuid references renters (id),         -- when set, only this renter may use the code
  source          text not null default 'manual',       -- 'followup_7d', 'followup_30d', 'manual', or another campaign name
  is_active       boolean not null default true,
  created_by      uuid references users (id),
  created_at      timestamptz not null default now(),
  check ((percent_bps is null) <> (amount_cents is null)),
  check (valid_until is null or valid_until > valid_from)
);
create unique index promo_codes_code_key on promo_codes (code);
create index promo_codes_renter_idx on promo_codes (renter_id);

-- ---------------------------------------------------------------- bookings: new columns
alter table bookings
  add column requested_at          timestamptz,
  add column request_note          text,                 -- the renter's note with the request, or with a change they ask for
  add column current_offer_version integer,
  add column offer_expires_at      timestamptz,
  add column offer_approved_version integer,
  add column offer_approved_at     timestamptz,
  add column offer_approved_by     uuid references users (id),
  -- a discount staff give on one booking, and a discount from a promo code; both come off the rental charge
  add column staff_discount_cents  bigint not null default 0 check (staff_discount_cents >= 0),
  add column staff_discount_reason text,
  add column promo_code_id         uuid references promo_codes (id),
  add column promo_discount_cents  bigint not null default 0 check (promo_discount_cents >= 0),
  -- the calendar switch
  add column blocks_calendar       boolean not null default true,
  add column blocks_calendar_changed_at timestamptz,
  add column blocks_calendar_changed_by uuid references users (id),
  add column blocks_calendar_reason text,
  -- who the bill goes to
  add column bill_to               text not null default 'renter' check (bill_to in ('renter', 'insurer', 'split')),
  add column insurer_id            uuid references insurers (id),
  add column insurer_claim_number  text,
  add column insurer_adjuster_name text,
  add column insurer_adjuster_email text,
  add column insurer_adjuster_phone text,
  add column insurer_authorized_daily_rate_cents bigint check (insurer_authorized_daily_rate_cents >= 0),
  add column insurer_authorized_days integer check (insurer_authorized_days > 0),
  add column insurer_authorized_until date,
  add column dates_provisional     boolean not null default false,
  -- the insurer's part of what is due at booking, before and of HST; the rest is the renter's
  add column insurer_share_cents   bigint not null default 0 check (insurer_share_cents >= 0),
  add column insurer_hst_cents     bigint not null default 0 check (insurer_hst_cents >= 0);
alter table bookings
  add column renter_due_at_booking_cents bigint
    generated always as (total_due_at_booking_cents - insurer_share_cents - insurer_hst_cents) stored;
alter table bookings
  add constraint bookings_discounts_within_rental check (discount_cents + staff_discount_cents + promo_discount_cents <= rental_charge_cents),
  add constraint bookings_staff_discount_reason check (staff_discount_cents = 0 or staff_discount_reason is not null),
  add constraint bookings_promo_discount_code check (promo_discount_cents = 0 or promo_code_id is not null),
  add constraint bookings_bill_to_insurer check (bill_to = 'renter' or insurer_id is not null),
  add constraint bookings_insurer_share_bill_to check (bill_to <> 'renter' or (insurer_share_cents = 0 and insurer_hst_cents = 0)),
  add constraint bookings_offer_approval check (offer_approved_version is null or (offer_approved_at is not null and offer_approved_by is not null));
comment on column bookings.blocks_calendar is 'False: the booking exists (even confirmed) without blocking the car, for example an insurer booking whose dates are not yet right. Flipping it to true runs the same overlap check as confirmation.';
create index bookings_offer_expiry_idx on bookings (offer_expires_at) where offer_expires_at is not null;
create index bookings_insurer_idx on bookings (insurer_id) where insurer_id is not null;

-- A new booking starts as a request. (Written through text for the reason at the top of this file.)
alter table bookings alter column status set default ('requested'::text)::booking_status;

-- The calendar rule. Before: one booking per car per moment among tentative, pending_payment,
-- confirmed and on_rent. Now: only a confirmed or on rent booking whose switch is on blocks.
do $$
declare
  c text;
begin
  select conname into strict c from pg_constraint where conrelid = 'public.bookings'::regclass and contype = 'x';
  execute format('alter table public.bookings drop constraint %I', c);
end $$;
alter table bookings add constraint bookings_no_double_booking
  exclude using gist (vehicle_id with =, rental_window with &&)
  where (status in ('confirmed', 'on_rent') and blocks_calendar);

-- ---------------------------------------------------------------- calendar blocks: removable without deleting
-- Nobody deletes from a browser session, so a block is removed by marking it removed.
alter table vehicle_calendar_blocks
  add column removed_at     timestamptz,
  add column removed_by     uuid references users (id),
  add column removed_reason text,
  add column updated_at     timestamptz not null default now();
create trigger vehicle_calendar_blocks_updated before update on vehicle_calendar_blocks
  for each row execute function app.set_updated_at();

-- ---------------------------------------------------------------- offers, one row per version sent
create table booking_offers (
  id               uuid primary key default gen_random_uuid(),
  booking_id       uuid not null references bookings (id) on delete cascade,
  version          integer not null check (version > 0),
  status           text not null default 'sent' check (status in (
                     'sent',              -- with the renter
                     'approved',          -- the renter approved this version
                     'change_requested',  -- the renter asked for a change
                     'declined',          -- the renter or CarmaCars declined
                     'expired',           -- not answered in time
                     'superseded',        -- replaced by a later version
                     'withdrawn')),       -- taken back by staff, or by the system when another booking took the car
  sent_by          uuid references users (id),     -- null: issued by the system (a promo code applied to an open offer)
  sent_at          timestamptz not null default now(),
  expires_at       timestamptz not null,
  message          text,                           -- to the customer
  -- the terms and price as sent
  vehicle_id       uuid not null references vehicles (id),
  pickup_at        timestamptz not null,
  return_at        timestamptz not null,
  billable_days    integer not null,
  rental_charge_cents bigint not null,
  discount_cents   bigint not null,                -- every discount on the rental charge, added up
  deposit_cents    bigint not null,
  subtotal_cents   bigint not null,
  hst_cents        bigint not null,
  total_cents      bigint not null,
  insurer_share_cents bigint not null default 0,   -- HST included
  renter_due_cents bigint not null,
  terms            jsonb not null,                 -- every other term of the booking as sent
  line_items       jsonb not null,                 -- the charge lines as sent
  responded_at     timestamptz,
  responded_by     uuid references users (id),
  response_note    text,
  created_at       timestamptz not null default now(),
  unique (booking_id, version),
  check (expires_at > sent_at)
);
create unique index booking_offers_one_open on booking_offers (booking_id) where status in ('sent', 'approved');
create index booking_offers_expiry_idx on booking_offers (expires_at) where status = 'sent';

-- What was sent is never rewritten: only the answer to it may change.
create or replace function app.guard_booking_offer() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if (to_jsonb(new) - array['status', 'responded_at', 'responded_by', 'response_note'])
     is distinct from (to_jsonb(old) - array['status', 'responded_at', 'responded_by', 'response_note']) then
    raise exception 'An offer that was sent cannot be rewritten; send a new version' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger booking_offers_guard before update on booking_offers
  for each row execute function app.guard_booking_offer();

-- ---------------------------------------------------------------- what happened to a request, in order
create table booking_events (
  id            bigint generated always as identity primary key,
  booking_id    uuid not null references bookings (id) on delete cascade,
  kind          text not null check (kind in (
                  'requested', 'adjusted', 'offer_sent', 'offer_approved', 'change_requested', 'declined',
                  'offer_withdrawn', 'offer_expired', 'pushed_back', 'calendar_switch', 'promo_applied', 'promo_removed')),
  from_status   text,
  to_status     text,
  offer_version integer,
  note          text,
  details       jsonb,
  actor_type    text not null check (actor_type in ('renter', 'staff', 'system')),
  actor_user_id uuid references users (id),
  created_at    timestamptz not null default now()
);
create index booking_events_booking_idx on booking_events (booking_id, id);
create trigger booking_events_append_only before update or delete on booking_events
  for each row execute function app.forbid_change();

-- ---------------------------------------------------------------- promo code use, one per booking
create table promo_redemptions (
  id             uuid primary key default gen_random_uuid(),
  promo_code_id  uuid not null references promo_codes (id),
  booking_id     uuid not null unique references bookings (id) on delete cascade,
  renter_id      uuid not null references renters (id),
  discount_cents bigint not null check (discount_cents >= 0),
  status         text not null default 'applied' check (status in (
                   'applied',    -- on a request or offer; counts as a use
                   'redeemed',   -- the booking was confirmed
                   'released')), -- the booking did not go ahead, or the code was taken off; the use is given back
  applied_by     uuid references users (id),
  applied_at     timestamptz not null default now(),
  redeemed_at    timestamptz,
  released_at    timestamptz
);
create index promo_redemptions_code_idx on promo_redemptions (promo_code_id, status);
create index promo_redemptions_renter_idx on promo_redemptions (renter_id);

-- ---------------------------------------------------------------- reviews
create table reviews (
  id             uuid primary key default gen_random_uuid(),
  booking_id     uuid not null unique references bookings (id),
  renter_id      uuid not null references renters (id),
  vehicle_id     uuid not null references vehicles (id),
  rating         smallint not null check (rating between 1 and 5),
  title          text,
  body           text,
  status         text not null default 'pending' check (status in ('pending', 'published', 'hidden')),
  staff_reply    text,
  staff_reply_by uuid references users (id),
  staff_reply_at timestamptz,
  moderated_by   uuid references users (id),
  published_at   timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  check (status <> 'published' or published_at is not null)
);
create index reviews_vehicle_idx on reviews (vehicle_id, published_at desc) where status = 'published';
create index reviews_renter_idx on reviews (renter_id);
create trigger reviews_updated before update on reviews for each row execute function app.set_updated_at();

-- One review per booking, by the renter of that booking, once it is closed.
create or replace function app.guard_review() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
begin
  if tg_op = 'INSERT' then
    select * into b from bookings where id = new.booking_id;
    if b.id is null or b.status <> 'closed' then
      raise exception 'A review can be left only once the booking is closed' using errcode = '23514';
    end if;
    if b.booking_type = 'owner' then
      raise exception 'An Owner Booking is not reviewed' using errcode = '23514';
    end if;
    if new.renter_id is distinct from b.renter_id then
      raise exception 'Only the renter of a booking may review it' using errcode = '23514';
    end if;
    new.vehicle_id := b.vehicle_id;
  elsif (new.booking_id, new.renter_id, new.vehicle_id) is distinct from (old.booking_id, old.renter_id, old.vehicle_id) then
    raise exception 'A review stays with its booking' using errcode = '23514';
  end if;
  if new.status = 'published' then
    new.published_at := coalesce(new.published_at, now());
  end if;
  if new.staff_reply is not null and (tg_op = 'INSERT' or new.staff_reply is distinct from old.staff_reply) then
    new.staff_reply_at := now();
  end if;
  return new;
end $$;
create trigger reviews_guard before insert or update on reviews
  for each row execute function app.guard_review();

-- ---------------------------------------------------------------- insurer invoices
-- Issued outside the card processor: sent to the insurer, paid by transfer or cheque.
create sequence insurer_invoice_number_seq start 5001;
create table insurer_invoices (
  id               uuid primary key default gen_random_uuid(),
  invoice_number   text not null unique default ('INS-' || nextval('insurer_invoice_number_seq')),
  booking_id       uuid not null references bookings (id),
  insurer_id       uuid not null references insurers (id),
  claim_number     text,
  period_start     date not null,
  period_end       date not null,
  amount_cents     bigint not null check (amount_cents >= 0),   -- before HST
  hst_cents        bigint not null default 0 check (hst_cents >= 0),
  total_cents      bigint generated always as (amount_cents + hst_cents) stored,
  status           text not null default 'draft' check (status in ('draft', 'sent', 'part_paid', 'paid', 'written_off')),
  lines            jsonb not null default '[]'::jsonb,           -- what the amount is made of, as printed
  sent_at          timestamptz,
  sent_by          uuid references users (id),
  paid_cents       bigint not null default 0 check (paid_cents >= 0),
  balance_cents    bigint generated always as (amount_cents + hst_cents - paid_cents) stored,
  paid_at          timestamptz,                                  -- when it was paid in full
  last_payment_reference text,
  written_off_at   timestamptz,
  written_off_by   uuid references users (id),
  written_off_reason text,
  document_id      uuid references documents (id),
  notes            text,
  created_by       uuid references users (id),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  check (period_end >= period_start),
  check (paid_cents <= amount_cents + hst_cents),
  check (status = 'draft' or sent_at is not null),
  check (status <> 'draft' or paid_cents = 0),
  check (status <> 'paid' or (paid_cents = amount_cents + hst_cents and paid_at is not null)),
  check (status <> 'part_paid' or (paid_cents > 0 and paid_cents < amount_cents + hst_cents)),
  check (status <> 'written_off' or (written_off_by is not null and written_off_reason is not null))
);
create unique index insurer_invoices_one_draft on insurer_invoices (booking_id) where status = 'draft';
create index insurer_invoices_insurer_idx on insurer_invoices (insurer_id, status);
create index insurer_invoices_booking_idx on insurer_invoices (booking_id);
create trigger insurer_invoices_updated before update on insurer_invoices for each row execute function app.set_updated_at();

-- ---------------------------------------------------------------- charge catalogue: the two new discounts
-- Both are negative lines on the rental charge and belong where the rental charge belongs
-- (Owner Revenue), exactly like the non-refundable discount.
insert into fee_types (code, label, family, unit, per_what, revenue_class, hst_applies, hst_as_invoiced, stage,
                       refundable_by_tier, change_default, change_vehicle, change_booking, in_master_spec, sort_order) values
  ('staff_discount', 'Discount given by CarmaCars on this booking, off the rental charge', 'rental', 'flat', 'rental', 'owner_revenue', true, false, 'booking', true, false, false, true,  false, 21),
  ('promo_discount', 'Promo code discount, off the rental charge',                         'rental', 'flat', 'rental', 'owner_revenue', true, false, 'booking', true, false, false, false, false, 22);

-- ---------------------------------------------------------------- who is acting (by user id)
-- The server acts for a named user and has no browser session, so these take the user's id.
create or replace function app.user_is_admin(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from user_roles r join users u on u.id = r.user_id
                  where r.user_id = p_user and r.role = 'admin' and u.status = 'active')
$$;

-- An active admin, or an active virtual assistant in any function.
create or replace function app.user_is_staff(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.user_is_admin(p_user) or exists (
    select 1 from user_roles r join users u on u.id = r.user_id
      join staff_profiles sp on sp.user_id = r.user_id and sp.staff_type = 'va' and sp.is_active
     where r.user_id = p_user and r.role = 'va' and u.status = 'active')
$$;

create or replace function app.is_booking_renter(p_booking uuid, p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from bookings b join renters r on r.id = b.renter_id
                  where b.id = p_booking and r.user_id = p_user)
$$;

create or replace function app.log_booking_event(p_booking uuid, p_kind text, p_from text, p_to text, p_version integer,
                                                 p_note text, p_actor uuid, p_actor_type text default null, p_details jsonb default null)
returns void language plpgsql security definer set search_path = public, app as $$
begin
  insert into booking_events (booking_id, kind, from_status, to_status, offer_version, note, details, actor_type, actor_user_id)
  values (p_booking, p_kind, p_from, p_to, p_version, p_note, p_details,
          coalesce(p_actor_type, case when p_actor is null then 'system'
                                      when app.is_booking_renter(p_booking, p_actor) and not app.user_is_staff(p_actor) then 'renter'
                                      else 'staff' end),
          p_actor);
end $$;

-- ---------------------------------------------------------------- availability
-- Is the car free for the whole of [p_from, p_to)? Only these make a car unavailable:
--   * a confirmed or on rent booking whose calendar switch is on (with the turnaround buffer
--     of program_settings on each side; the buffer is 0 unless an admin sets it), and
--   * a calendar block that has not been removed.
-- A request, an offer and a booking waiting for signature and payment never count.
create or replace function app.vehicle_is_available(p_vehicle uuid, p_from timestamptz, p_to timestamptz,
                                                    p_ignore_booking uuid default null)
returns boolean language plpgsql stable security definer set search_path = public, app as $$
declare
  v_buffer interval := make_interval(mins => coalesce((app.settings()).turnaround_buffer_minutes, 0));
begin
  if p_vehicle is null or p_from is null or p_to is null or p_to <= p_from then
    return false;
  end if;
  return not exists (
           select 1 from bookings b
            where b.vehicle_id = p_vehicle and b.blocks_calendar and b.status in ('confirmed', 'on_rent')
              and (p_ignore_booking is null or b.id <> p_ignore_booking)
              and b.pickup_at - v_buffer < p_to and b.return_at + v_buffer > p_from)
     and not exists (
           select 1 from vehicle_calendar_blocks c
            where c.vehicle_id = p_vehicle and c.removed_at is null
              and c.starts_at < p_to and (c.ends_at is null or c.ends_at > p_from));
end $$;

-- The public calendar of one listed car: the stretches when it cannot be booked, and nothing
-- else. No booking, no person, no reason. Dates are Toronto dates; at most 366 days per call.
-- Safe for the anonymous role: it answers only for a car on the public listing.
create or replace function app.public_vehicle_calendar(p_vehicle uuid, p_from date, p_to date)
returns table (unavailable_from timestamptz, unavailable_to timestamptz, first_date date, last_date date)
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_buffer interval := make_interval(mins => coalesce((app.settings()).turnaround_buffer_minutes, 0));
  v_window tstzrange;
begin
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then
    raise exception 'Ask for a range of 1 to 366 days' using errcode = '22023';
  end if;
  if not exists (select 1 from public_vehicle_listings l where l.vehicle_id = p_vehicle) then
    return;
  end if;
  v_window := tstzrange(app.local_midnight(p_from), app.local_midnight(p_to + 1), '[)');
  return query
    with busy as (
      select tstzrange(b.pickup_at - v_buffer, b.return_at + v_buffer, '[)') * v_window as r
        from bookings b
       where b.vehicle_id = p_vehicle and b.blocks_calendar and b.status in ('confirmed', 'on_rent')
         and tstzrange(b.pickup_at - v_buffer, b.return_at + v_buffer, '[)') && v_window
      union all
      select tstzrange(c.starts_at, c.ends_at, '[)') * v_window
        from vehicle_calendar_blocks c
       where c.vehicle_id = p_vehicle and c.removed_at is null
         and tstzrange(c.starts_at, c.ends_at, '[)') && v_window
    ), merged as (
      select unnest(range_agg(r)) as r from busy
    )
    select lower(m.r), upper(m.r), app.local_date(lower(m.r)), app.local_date(upper(m.r) - interval '1 microsecond')
      from merged m order by 1;
end $$;

-- ---------------------------------------------------------------- pricing a request
-- The insurer's part of a booking, worked out from its charge lines.
--   Rental part  = rental charge less every discount (booking and extension lines).
--   The insurer pays the rental part for the days it authorized, at no more than the daily rate
--   it authorized. bill_to = 'insurer': it also pays the other fees charged at booking.
--   bill_to = 'split': it pays the rental part only. Everything else is the renter's: any rental
--   amount above the authorization, the Deposit, and every charge after the rental.
--   Days authorized = the lower of "authorized days" and the rental days that start on or before
--   the "authorized until" date (Toronto), when either is given.
create or replace function app.booking_insurer_share(p_booking uuid)
returns table (covered_days integer, rental_share_cents bigint, fees_share_cents bigint, share_cents bigint, hst_cents bigint)
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  v_rental bigint; v_rental_hst bigint; v_fees bigint; v_fees_hst bigint;
  v_days integer; v_until_days integer;
  v_r bigint; v_f bigint; v_h bigint;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null then raise exception 'Booking % not found', p_booking; end if;
  if b.bill_to = 'renter' or b.booking_type = 'owner' then
    return query select 0, 0::bigint, 0::bigint, 0::bigint, 0::bigint;
    return;
  end if;
  select coalesce(sum(li.amount_cents) filter (where f.family = 'rental'), 0),
         coalesce(sum(li.hst_cents) filter (where f.family = 'rental'), 0),
         coalesce(sum(li.amount_cents) filter (where f.family <> 'rental'), 0),
         coalesce(sum(li.hst_cents) filter (where f.family <> 'rental'), 0)
    into v_rental, v_rental_hst, v_fees, v_fees_hst
    from booking_line_items li join fee_types f on f.code = li.charge_type
   where li.booking_id = p_booking and li.voided_at is null and li.charged_to_renter and li.stage in ('booking', 'extension');

  v_days := b.billable_days;
  if b.insurer_authorized_until is not null then
    v_until_days := case when app.local_midnight(b.insurer_authorized_until + 1) <= b.pickup_at then 0
                         else public.calc_billable_days(b.pickup_at, app.local_midnight(b.insurer_authorized_until + 1)) end;
    v_days := least(v_days, v_until_days);
  end if;
  if b.insurer_authorized_days is not null then
    v_days := least(v_days, b.insurer_authorized_days);
  end if;

  v_r := case when b.insurer_authorized_daily_rate_cents is not null
              then least(greatest(v_rental, 0), b.insurer_authorized_daily_rate_cents * v_days)
              else public.calc_round(greatest(v_rental, 0)::numeric * v_days / b.billable_days) end;
  v_f := case when b.bill_to = 'insurer' then greatest(v_fees, 0) else 0 end;
  v_h := case when v_rental > 0 then public.calc_round(v_rental_hst::numeric * v_r / v_rental) else 0 end
       + case when b.bill_to = 'insurer' then greatest(v_fees_hst, 0) else 0 end;
  return query select v_days, v_r, v_f, v_r + v_f, v_h;
end $$;

-- A promo code's discount on a rental charge of p_base_cents (already net of other discounts).
create or replace function app.promo_discount_cents(p_promo uuid, p_base_cents bigint) returns bigint
language sql stable security definer set search_path = public, app as $$
  select case when p_base_cents <= 0 then 0
              when pc.percent_bps is not null then least(public.calc_bps(p_base_cents, pc.percent_bps), p_base_cents)
              else least(pc.amount_cents, p_base_cents) end
    from promo_codes pc where pc.id = p_promo
$$;

-- One price line of a booking, kept in step with the booking: created, changed, or voided when
-- the amount is nil. Lines are never deleted.
create or replace function app.set_price_line(p_booking uuid, p_charge_type text, p_amount_cents bigint, p_hst_bps integer)
returns void language plpgsql security definer set search_path = public, app as $$
declare
  f fee_types;
  v_line booking_line_items;
  v_hst bigint;
begin
  select * into f from fee_types where code = p_charge_type;
  if f.code is null then raise exception 'Unknown charge type %', p_charge_type; end if;
  select * into v_line from booking_line_items
   where booking_id = p_booking and charge_type = p_charge_type and stage = 'booking' and voided_at is null
   order by created_at, id limit 1;
  if p_amount_cents = 0 then
    if v_line.id is not null then
      update booking_line_items set voided_at = now(), void_reason = 'no longer applies' where id = v_line.id;
    end if;
    return;
  end if;
  v_hst := case when f.hst_applies then public.calc_hst(p_amount_cents, p_hst_bps) else 0 end;
  if v_line.id is null then
    insert into booking_line_items (booking_id, charge_type, description, quantity, unit_amount_cents, amount_cents,
                                    hst_applies, hst_cents, revenue_class, stage)
    values (p_booking, p_charge_type, f.label, 1, p_amount_cents, p_amount_cents, f.hst_applies, v_hst, f.revenue_class, 'booking');
  elsif (v_line.amount_cents, v_line.hst_cents) is distinct from (p_amount_cents, v_hst) then
    update booking_line_items set unit_amount_cents = p_amount_cents, amount_cents = p_amount_cents, quantity = 1, hst_cents = v_hst
     where id = v_line.id;
  end if;
end $$;

-- Bring a booking's price lines and totals in step with the booking itself: the rental charge
-- and its discounts (non-refundable, staff, promo code), a delivery or pickup fee from the rate
-- card when the booking calls for one and has none yet, then the totals and the insurer's part.
-- HST is worked out per line and the totals are the sum of the lines. Other fee lines are left
-- as staff entered them. Allowed while a booking is a request, or while its dates are provisional.
create or replace function app.reprice_booking(p_booking uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  rc rate_cards;
  v_promo bigint := 0;
  v_sub bigint; v_hst bigint;
  s record;
begin
  select * into b from bookings where id = p_booking for update;
  if b.id is null then raise exception 'Booking % not found', p_booking; end if;
  if not (b.status in ('requested', 'tentative') or (b.dates_provisional and b.status in ('confirmed', 'on_rent'))) then
    raise exception 'Booking % is % and its price is settled', b.booking_number, b.status using errcode = '23514';
  end if;

  if b.promo_code_id is not null then
    v_promo := coalesce(app.promo_discount_cents(b.promo_code_id, b.rental_charge_cents - b.discount_cents - b.staff_discount_cents), 0);
  end if;
  if v_promo is distinct from b.promo_discount_cents then
    update bookings set promo_discount_cents = v_promo where id = p_booking;
    update promo_redemptions set discount_cents = v_promo where booking_id = p_booking and status <> 'released';
  end if;

  if b.booking_type <> 'owner' then
    perform app.set_price_line(p_booking, 'rental_charge', b.rental_charge_cents, b.hst_bps);
    perform app.set_price_line(p_booking, 'non_refundable_discount', -b.discount_cents, b.hst_bps);
    perform app.set_price_line(p_booking, 'staff_discount', -b.staff_discount_cents, b.hst_bps);
    perform app.set_price_line(p_booking, 'promo_discount', -v_promo, b.hst_bps);
    -- delivery and pickup: the rate card's fee when there is no line yet; no line when not asked for
    select * into rc from rate_cards r
     where r.vehicle_id = b.vehicle_id and r.effective_from <= now() and (r.effective_to is null or r.effective_to > now());
    if b.pickup_method <> 'delivered' then
      perform app.set_price_line(p_booking, 'delivery', 0, b.hst_bps);
    elsif not exists (select 1 from booking_line_items where booking_id = p_booking and charge_type = 'delivery' and stage = 'booking' and voided_at is null) then
      perform app.set_price_line(p_booking, 'delivery', coalesce(rc.delivery_fee_cents, 0), b.hst_bps);
    end if;
    if b.return_method <> 'picked_up' then
      perform app.set_price_line(p_booking, 'pickup', 0, b.hst_bps);
    elsif not exists (select 1 from booking_line_items where booking_id = p_booking and charge_type = 'pickup' and stage = 'booking' and voided_at is null) then
      perform app.set_price_line(p_booking, 'pickup', coalesce(rc.pickup_fee_cents, 0), b.hst_bps);
    end if;
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

-- ---------------------------------------------------------------- bookings: fill the snapshot, check each step
-- Replaces the function of migration 0011. What is new:
--   * requested and offered count as "still being arranged" (rates may change; the vehicle must be bookable);
--   * swapping the vehicle of a request takes the new vehicle's owner, mode and Revenue Share;
--   * once an offer is out, its terms stand still until it is withdrawn;
--   * offered needs an offer that was sent; pending_payment needs that offer approved
--     (an Owner Booking, with nothing to pay, goes from requested straight to signing);
--   * confirmed, or the calendar switch turned on, needs the car to be free;
--   * a booking billed to an insurer with nothing due from the renter needs no card payment;
--   * the calendar switch changes only with who and why.
create or replace function app.booking_before_write() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  v_set program_settings;
  prev bookings;
  v_arranging constant text[] := array['requested', 'offered', 'tentative', 'pending_payment'];
begin
  v_set := app.settings(app.local_date(coalesce(new.booked_at, now())));
  -- the non-refundable discount is fixed: 10% off the rental charge only, never off fees
  if new.booking_type = 'non_refundable'
     and new.discount_cents <> public.calc_bps(new.rental_charge_cents, v_set.non_refundable_discount_bps) then
    raise exception 'The non-refundable discount is fixed at % basis points of the rental charge', v_set.non_refundable_discount_bps
      using errcode = '23514';
  end if;
  if tg_op = 'INSERT' then
    select * into v from vehicles where id = new.vehicle_id;
    -- snapshot of who owns the vehicle and how it is managed
    new.owner_id := coalesce(new.owner_id, v.owner_id);
    new.management_mode := coalesce(new.management_mode, v.management_mode);
    new.is_shareholder_vehicle := v.is_shareholder_owned;
    if new.company_share_bps is null then
      new.company_share_bps := case
        when new.booking_type = 'owner' then 0
        when v.is_shareholder_owned then v_set.shareholder_company_share_bps
        when v.management_mode = 'self_managed' then 0
        else coalesce((app.vehicle_terms(v.id, app.local_date(coalesce(new.booked_at, now())))).revenue_share_bps,
                      (select s.revenue_share_bps from vehicle_schedules s where s.vehicle_id = v.id and s.superseded_by is null)) end;
    end if;
    if new.booking_type = 'owner' then
      -- only the vehicle's Owner makes an Owner Booking
      if not exists (select 1 from renters r join owners o on o.user_id = r.user_id
                      where r.id = new.renter_id and o.id = v.owner_id)
         and (new.status::text = any (v_arranging) or new.status = 'confirmed') then
        raise exception 'An Owner Booking is made by the vehicle''s own Owner' using errcode = '23514';
      end if;
    elsif new.status::text = any (v_arranging) or new.status = 'confirmed' then
      if not coalesce(app.vehicle_bookable(new.vehicle_id), false) then
        raise exception 'Vehicle is not open for new bookings' using errcode = '23514';
      end if;
      if v.exit_date is not null and app.local_date(new.return_at) > v.exit_date then
        raise exception 'The booking would run past the vehicle''s Exit Date' using errcode = '23514';
      end if;
    end if;
    -- a renewal: same renter, made before the current rental ends
    if new.renews_booking_id is not null then
      select * into prev from bookings where id = new.renews_booking_id;
      if prev.renter_id <> new.renter_id then
        raise exception 'A renewal belongs to the same renter as the booking it renews' using errcode = '23514';
      end if;
      if (new.status::text = any (v_arranging) or new.status = 'confirmed') and new.booked_at > coalesce(prev.checked_in_at, prev.return_at) then
        raise exception 'A renewal is made before the current rental ends' using errcode = '23514';
      end if;
    end if;
    if new.status = 'requested' then
      new.requested_at := coalesce(new.requested_at, new.booked_at, now());
    end if;
    return new;
  end if;

  -- UPDATE
  -- an extension past 7 days in total: the card hold must be captured first
  if new.billable_days > old.billable_days
     and new.billable_days > (app.settings()).deposit_hold_max_days
     and exists (select 1 from deposits d where d.booking_id = new.id and d.method = 'card_hold' and d.status = 'held') then
    raise exception 'Total length is now over 7 days: capture the card hold as a charged Deposit first' using errcode = '23514';
  end if;

  -- a request moved to another vehicle takes that vehicle's owner, mode and Revenue Share
  if new.vehicle_id is distinct from old.vehicle_id and old.status in ('requested', 'tentative') and new.status = old.status then
    select * into v from vehicles where id = new.vehicle_id;
    new.owner_id := v.owner_id;
    new.management_mode := v.management_mode;
    new.is_shareholder_vehicle := v.is_shareholder_owned;
    new.company_share_bps := case
      when new.booking_type = 'owner' then 0
      when v.is_shareholder_owned then v_set.shareholder_company_share_bps
      when v.management_mode = 'self_managed' then 0
      else coalesce((app.vehicle_terms(v.id, app.local_date(coalesce(new.booked_at, now())))).revenue_share_bps,
                    (select s.revenue_share_bps from vehicle_schedules s where s.vehicle_id = v.id and s.superseded_by is null)) end;
    if new.booking_type = 'owner' then
      if not exists (select 1 from renters r join owners o on o.user_id = r.user_id
                      where r.id = new.renter_id and o.id = v.owner_id) then
        raise exception 'An Owner Booking is made by the vehicle''s own Owner' using errcode = '23514';
      end if;
    else
      if not coalesce(app.vehicle_bookable(new.vehicle_id), false) then
        raise exception 'Vehicle is not open for new bookings' using errcode = '23514';
      end if;
      if v.exit_date is not null and app.local_date(new.return_at) > v.exit_date then
        raise exception 'The booking would run past the vehicle''s Exit Date' using errcode = '23514';
      end if;
    end if;
  end if;

  -- a booking always uses the rates stored on it
  if not (old.status::text = any (v_arranging))
     and (new.daily_rate_cents, new.weekend_rate_cents, new.weekly_rate_cents, new.monthly_rate_cents,
          new.km_allowance_per_day, new.overage_cents_per_km, new.company_share_bps, new.owner_id, new.management_mode)
         is distinct from
         (old.daily_rate_cents, old.weekend_rate_cents, old.weekly_rate_cents, old.monthly_rate_cents,
          old.km_allowance_per_day, old.overage_cents_per_km, old.company_share_bps, old.owner_id, old.management_mode) then
    raise exception 'The rates and split terms stored on a confirmed booking cannot change' using errcode = '23514';
  end if;

  -- an offer that is out is what the renter approves: its terms stand still until it is withdrawn
  if old.status in ('offered', 'pending_payment') and new.status = old.status and old.current_offer_version is not null
     and (new.vehicle_id, new.booking_type, new.pickup_at, new.return_at,
          new.daily_rate_cents, new.weekend_rate_cents, new.weekly_rate_cents, new.monthly_rate_cents,
          new.rental_charge_cents, new.discount_cents, new.staff_discount_cents, new.promo_discount_cents, new.promo_code_id,
          new.km_allowance_per_day, new.overage_cents_per_km, new.deposit_cents,
          new.pickup_method, new.return_method, new.pickup_place, new.return_place,
          new.bill_to, new.insurer_id, new.insurer_authorized_daily_rate_cents, new.insurer_authorized_days, new.insurer_authorized_until,
          new.total_due_at_booking_cents, new.insurer_share_cents, new.insurer_hst_cents)
         is distinct from
         (old.vehicle_id, old.booking_type, old.pickup_at, old.return_at,
          old.daily_rate_cents, old.weekend_rate_cents, old.weekly_rate_cents, old.monthly_rate_cents,
          old.rental_charge_cents, old.discount_cents, old.staff_discount_cents, old.promo_discount_cents, old.promo_code_id,
          old.km_allowance_per_day, old.overage_cents_per_km, old.deposit_cents,
          old.pickup_method, old.return_method, old.pickup_place, old.return_place,
          old.bill_to, old.insurer_id, old.insurer_authorized_daily_rate_cents, old.insurer_authorized_days, old.insurer_authorized_until,
          old.total_due_at_booking_cents, old.insurer_share_cents, old.insurer_hst_cents) then
    raise exception 'An offer has been sent: withdraw it (back to requested) before changing its terms' using errcode = '23514';
  end if;

  -- a bill that goes to the renter alone carries no insurer part
  if new.bill_to = 'renter' then
    new.insurer_share_cents := 0;
    new.insurer_hst_cents := 0;
  end if;

  -- the calendar switch: who and why, every time
  if new.blocks_calendar is distinct from old.blocks_calendar then
    if pg_catalog.current_setting('role', true) = 'authenticated' then
      new.blocks_calendar_changed_by := app.uid();
    end if;
    if new.blocks_calendar_changed_by is null or btrim(coalesce(new.blocks_calendar_reason, '')) = ''
       or new.blocks_calendar_reason is not distinct from old.blocks_calendar_reason then
      raise exception 'Changing the calendar switch needs who is changing it and a reason for this change' using errcode = '23514';
    end if;
    new.blocks_calendar_changed_at := now();
  end if;

  if new.status is distinct from old.status then
    if new.status = 'requested' then
      -- back with staff: the approval and the deadline of the earlier offer no longer stand
      new.offer_expires_at := null;
      new.offer_approved_version := null;
      new.offer_approved_at := null;
      new.offer_approved_by := null;
      new.requested_at := coalesce(new.requested_at, now());
    elsif new.status = 'offered' then
      if new.offer_expires_at is null or not exists (
           select 1 from booking_offers o
            where o.booking_id = new.id and o.version = new.current_offer_version and o.status = 'sent') then
        raise exception 'A booking is offered only by sending an offer' using errcode = '23514';
      end if;
    elsif new.status = 'pending_payment' then
      if old.status = 'offered' then
        if new.offer_approved_version is null or new.offer_approved_version is distinct from new.current_offer_version
           or not exists (select 1 from booking_offers o
                           where o.booking_id = new.id and o.version = new.current_offer_version and o.status = 'approved') then
          raise exception 'The renter must approve the current offer before signing and payment' using errcode = '23514';
        end if;
      elsif old.status = 'requested' and new.booking_type <> 'owner' then
        raise exception 'Only an Owner Booking goes to signing without an offer' using errcode = '23514';
      end if;
    elsif new.status = 'confirmed' then
      if not exists (select 1 from signature_requests s where s.id = new.signature_request_id and s.status = 'completed') then
        raise exception 'A booking is confirmed only when the agreement is signed' using errcode = '23514';
      end if;
      -- billed to an insurer with nothing due from the renter: there is no card payment to wait for
      if new.booking_type <> 'owner'
         and not (new.bill_to <> 'renter'
                  and new.total_due_at_booking_cents - new.insurer_share_cents - new.insurer_hst_cents <= 0)
         and not exists (
           select 1 from payments p where p.booking_id = new.id and p.purpose = 'booking_total'
              and p.kind = 'charge' and p.status = 'succeeded') then
        raise exception 'A booking is confirmed only when payment succeeds' using errcode = '23514';
      end if;
      if new.booking_type <> 'owner' and new.card_on_file_id is null then
        raise exception 'No saved card, no confirmed booking' using errcode = '23514';
      end if;
      new.confirmed_at := coalesce(new.confirmed_at, now());
    elsif new.status = 'on_rent' then
      if exists (select 1 from booking_drivers d where d.booking_id = new.id and d.identity_verified_on is null)
         or not exists (select 1 from booking_drivers d where d.booking_id = new.id and d.role = 'renter') then
        raise exception 'No car is released until every driver''s identity is verified' using errcode = '23514';
      end if;
      if new.booking_type <> 'owner' then
        if new.coverage_confirmed_at is null or not exists (
             select 1 from coverage_proofs c where c.booking_id = new.id and c.status = 'confirmed') then
          raise exception 'No car is released until a Coverage Option is confirmed' using errcode = '23514';
        end if;
        if new.deposit_cents > 0 and not exists (
             select 1 from deposits d where d.booking_id = new.id and d.status in ('held', 'captured')) then
          raise exception 'The Deposit is taken at pickup, before handover' using errcode = '23514';
        end if;
      end if;
      if not exists (select 1 from condition_reports c where c.booking_id = new.id and c.kind = 'pickup') then
        raise exception 'Handover needs the pickup Condition Report' using errcode = '23514';
      end if;
      new.handed_over_at := coalesce(new.handed_over_at, now());
    elsif new.status = 'returned' then
      if not exists (select 1 from condition_reports c where c.booking_id = new.id and c.kind = 'return') then
        raise exception 'Check-in needs the return Condition Report' using errcode = '23514';
      end if;
      new.checked_in_at := coalesce(new.checked_in_at, now());
    elsif new.status in ('cancelled', 'no_show') and old.status = 'confirmed' then
      if not exists (select 1 from booking_cancellations c where c.booking_id = new.id) then
        raise exception 'Log the cancellation (booking made, cancellation received, start) before cancelling' using errcode = '23514';
      end if;
    end if;
  end if;

  -- the car must be free whenever a booking starts to block it, or moves while blocking it
  if new.blocks_calendar and new.status in ('confirmed', 'on_rent')
     and (old.status not in ('confirmed', 'on_rent') or not old.blocks_calendar
          or new.vehicle_id is distinct from old.vehicle_id
          or new.pickup_at is distinct from old.pickup_at or new.return_at is distinct from old.return_at)
     and not app.vehicle_is_available(new.vehicle_id, new.pickup_at, new.return_at, new.id) then
    raise exception 'The vehicle is not available for these dates: a confirmed booking or a calendar block overlaps'
      using errcode = '23P01';
  end if;
  return new;
end $$;

-- After a change: log the calendar switch, keep promo code use in step with the booking, and
-- when this booking has just started to block the car, send every competing offer back to staff.
create or replace function app.booking_request_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_buffer interval;
  r record;
  v_paid boolean;
begin
  if new.blocks_calendar is distinct from old.blocks_calendar then
    perform app.log_booking_event(new.id, 'calendar_switch', old.status::text, new.status::text, null, new.blocks_calendar_reason,
      new.blocks_calendar_changed_by, 'staff', jsonb_build_object('blocks_calendar', new.blocks_calendar));
  end if;

  if new.status is distinct from old.status then
    if new.status = 'confirmed' then
      update promo_redemptions set status = 'redeemed', redeemed_at = now() where booking_id = new.id and status = 'applied';
    elsif new.status in ('declined', 'expired', 'cancelled') then
      update promo_redemptions set status = 'released', released_at = now() where booking_id = new.id and status = 'applied';
    end if;
    -- a status written directly (not through the functions below) must not leave an offer open
    if old.status in ('offered', 'pending_payment') and new.status in ('requested', 'declined', 'expired', 'cancelled') then
      update booking_offers
         set status = case when new.status = 'requested' then 'withdrawn' when new.status = 'expired' then 'expired' else 'declined' end,
             responded_at = now()
       where booking_id = new.id and status in ('sent', 'approved');
    end if;
  end if;

  if new.blocks_calendar and new.status in ('confirmed', 'on_rent')
     and (old.status not in ('confirmed', 'on_rent') or not old.blocks_calendar
          or new.vehicle_id is distinct from old.vehicle_id
          or new.pickup_at is distinct from old.pickup_at or new.return_at is distinct from old.return_at) then
    v_buffer := make_interval(mins => coalesce((app.settings()).turnaround_buffer_minutes, 0));
    for r in
      select o.id, o.booking_number, o.status, o.current_offer_version, o.renter_id
        from bookings o
       where o.vehicle_id = new.vehicle_id and o.id <> new.id and o.blocks_calendar
         and o.status in ('offered', 'pending_payment')
         and o.pickup_at < new.return_at + v_buffer and o.return_at > new.pickup_at - v_buffer
       order by o.booked_at, o.id
       for update
    loop
      v_paid := exists (select 1 from payments p where p.booking_id = r.id and p.purpose = 'booking_total'
                           and p.kind = 'charge' and p.status = 'succeeded');
      update booking_offers
         set status = 'withdrawn', responded_at = now(),
             response_note = format('Booking %s was confirmed on this vehicle for overlapping dates', new.booking_number)
       where booking_id = r.id and status in ('sent', 'approved');
      update bookings set status = 'requested' where id = r.id;
      perform app.log_booking_event(r.id, 'pushed_back', r.status::text, 'requested', r.current_offer_version,
        format('Booking %s was confirmed on this vehicle for overlapping dates. This request is back with staff: offer another vehicle or other dates.',
               new.booking_number), null, 'system');
      insert into tasks (queue, task_type, title, detail, procedure_no, priority, booking_id, vehicle_id, renter_id)
      values ('cs', 'reoffer_booking', format('Re-offer booking %s: the car was taken', r.booking_number),
              format('Booking %s was confirmed on the same vehicle for overlapping dates, so the offer on %s was withdrawn. Offer another vehicle or other dates, or decline.%s',
                     new.booking_number, r.booking_number,
                     case when v_paid then ' A PAYMENT WAS ALREADY TAKEN on this booking: refund it or apply it to the new offer.' else '' end),
              1, case when v_paid then 'urgent' else 'high' end, r.id, new.vehicle_id, r.renter_id);
    end loop;
  end if;
  return null;
end $$;
create trigger bookings_request_after after update on bookings
  for each row execute function app.booking_request_after();

-- Columns of the request flow that a browser session may change only as an Admin. The server
-- sets them through the functions below. (Only an Admin gives a discount on a booking.)
create trigger bookings_guard_request_columns before update on bookings
  for each row execute function app.guard_admin_columns(
    'staff_discount_cents', 'promo_code_id', 'promo_discount_cents', 'current_offer_version', 'offer_expires_at',
    'offer_approved_version', 'offer_approved_at', 'offer_approved_by');

-- The referrer may still be set while a booking is a request or an offer.
create or replace function app.resolve_referrer() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_owner uuid;
  v_staff uuid;
begin
  if tg_op = 'UPDATE' and old.status not in ('requested', 'offered', 'tentative', 'pending_payment')
     and (new.referrer_type is distinct from old.referrer_type
          or new.referrer_owner_id is distinct from old.referrer_owner_id
          or new.referrer_staff_id is distinct from old.referrer_staff_id
          or new.referred_by_code is distinct from old.referred_by_code) then
    raise exception 'A referrer must be linked before the booking is made; it cannot change afterwards' using errcode = '23514';
  end if;
  if new.referred_by_code is not null and new.referrer_type is null then
    select id into v_owner from owners where upper(referral_code) = upper(new.referred_by_code);
    if v_owner is not null then
      new.referrer_type := 'owner'; new.referrer_owner_id := v_owner;
    else
      select user_id into v_staff from staff_profiles
       where upper(referral_code) = upper(new.referred_by_code) and staff_type = 'field';
      if v_staff is not null then
        new.referrer_type := 'field_staff'; new.referrer_staff_id := v_staff;
      end if;
    end if;
  end if;
  -- virtual assistants earn no referral fee
  if new.referrer_staff_id is not null and not exists (
       select 1 from staff_profiles sp where sp.user_id = new.referrer_staff_id and sp.staff_type = 'field') then
    raise exception 'Only in-person field staff can be a staff referrer' using errcode = '23514';
  end if;
  return new;
end $$;

-- ---------------------------------------------------------------- status flow
-- Added for request to book. Nothing is removed: the tentative rows of migration 0011 stay
-- because the existing tests walk tentative -> pending_payment -> confirmed, and a record
-- imported in the old shape must still be able to move. No function here uses them.
insert into status_transitions (entity, from_status, to_status, note) values
  ('booking', 'requested', 'offered', 'staff sent an offer'),
  ('booking', 'requested', 'pending_payment', 'Owner Booking only: agreement sent for signature, nothing to pay'),
  ('booking', 'requested', 'declined', 'CarmaCars refuses the request, or the renter withdraws it'),
  ('booking', 'offered', 'pending_payment', 'the renter approved the current offer: signing and payment in progress'),
  ('booking', 'offered', 'requested', 'the renter asked for a change, staff withdrew the offer, it expired, or another booking took the car'),
  ('booking', 'offered', 'declined', 'the renter or CarmaCars declined'),
  ('booking', 'pending_payment', 'requested', 'the renter asked for a change, staff withdrew the offer, or another booking took the car');
update status_transitions set note = 'old flow (before request to book): ' || coalesce(note, 'not used by the request flow')
 where entity = 'booking' and from_status = 'tentative';

-- ---------------------------------------------------------------- the split counts the new discounts
-- app.compute_booking_split() of migration 0007, word for word, with one change made in two
-- places: the staff discount and the promo code discount are part of the rental charge, next to
-- the non-refundable discount. So a discount comes off the rental charge before the kickback,
-- Owner Revenue and the Revenue Share are worked out, exactly as the existing discount does.
create or replace function app.compute_booking_split(p_booking uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  s booking_splits;
  v_set program_settings;
  v_rental bigint; v_mileage bigint; v_company bigint; v_pass bigint; v_hst bigint;
  v_ref_rental bigint; v_ref_mileage bigint;
  v_collected bigint; v_refunded bigint; v_chargeback bigint; v_withheld bigint; v_uncollected bigint;
  v_reason text; v_kick bigint; v_rev bigint; v_share bigint; v_pay bigint;
  v_counts date; v_done boolean; v_cancelled boolean;
  v_prior bigint; v_delta bigint;
begin
  select * into b from bookings where id = p_booking;
  if not found then raise exception 'Booking % not found', p_booking; end if;
  -- an Owner Booking has no Owner Revenue, kickback or payout
  if b.booking_type = 'owner' then
    delete from booking_splits where booking_id = p_booking and owner_statement_id is null;
    return;
  end if;
  v_set := app.settings(app.local_date(b.booked_at));
  v_cancelled := b.status in ('cancelled', 'no_show');
  v_done := b.status in ('returned', 'closed');

  select coalesce(sum(amount_cents) filter (where charge_type in ('rental_charge', 'non_refundable_discount', 'staff_discount', 'promo_discount', 'late_return_extra_days')), 0),
         coalesce(sum(amount_cents) filter (where charge_type = 'mileage_overage'), 0),
         coalesce(sum(amount_cents) filter (where revenue_class = 'company_only'), 0),
         coalesce(sum(amount_cents) filter (where revenue_class = 'pass_through'), 0),
         coalesce(sum(hst_cents) filter (where charged_to_renter), 0),
         coalesce(sum(amount_cents) filter (where revenue_class = 'owner_revenue' and not exists (
             select 1 from payments p where p.id = li.payment_id and p.status = 'succeeded')), 0)
    into v_rental, v_mileage, v_company, v_pass, v_hst, v_uncollected
    from booking_line_items li
   where li.booking_id = p_booking and li.voided_at is null and li.charged_to_renter;

  select coalesce(sum(ra.amount_cents) filter (where li.charge_type in ('rental_charge', 'non_refundable_discount', 'staff_discount', 'promo_discount', 'late_return_extra_days')), 0),
         coalesce(sum(ra.amount_cents) filter (where li.charge_type = 'mileage_overage'), 0)
    into v_ref_rental, v_ref_mileage
    from refund_allocations ra
    join refunds r on r.id = ra.refund_id and r.status in ('approved', 'processing', 'paid')
    join booking_line_items li on li.id = ra.line_item_id
   where li.booking_id = p_booking and li.voided_at is null;

  select coalesce(sum(amount_cents) filter (where kind in ('charge', 'capture') and purpose <> 'deposit'), 0)
    into v_collected from payments where booking_id = p_booking and status = 'succeeded';
  select coalesce(sum(amount_cents), 0) into v_refunded
    from refunds where booking_id = p_booking and status in ('approved', 'processing', 'paid');
  select coalesce(sum(owner_revenue_reversed_cents) filter (where status = 'lost'), 0),
         coalesce(sum(owner_revenue_withheld_cents) filter (where status in ('open', 'evidence_submitted')), 0)
    into v_chargeback, v_withheld from disputes where booking_id = p_booking;

  v_rental := v_rental - v_ref_rental;
  v_mileage := v_mileage - v_ref_mileage;
  -- Owner Revenue lost to a chargeback comes off the rental charge
  v_rental := greatest(v_rental - v_chargeback, 0);

  v_reason := app.kickback_ineligible_reason(p_booking);
  v_kick := public.calc_kickback(v_rental, v_reason is null, v_set.kickback_bps);
  select owner_revenue_cents, company_share_cents, owner_payout_cents into v_rev, v_share, v_pay
    from public.calc_split(v_rental, v_mileage, v_kick, b.company_share_bps);

  -- A rental counts in the month it ends; rental charge kept on a cancellation, in the month of cancellation.
  if v_cancelled then
    select app.local_date(received_at) into v_counts from booking_cancellations where booking_id = p_booking;
    v_counts := coalesce(v_counts, app.local_date(b.updated_at));
  else
    v_counts := app.local_date(coalesce(b.checked_in_at, b.return_at));
  end if;

  select * into s from booking_splits where booking_id = p_booking;
  if s.booking_id is not null and s.owner_statement_id is not null then
    -- already paid out: the Owner's share of the change goes on the next statement
    select coalesce(sum(amount_cents), 0) into v_prior from owner_deductions
     where booking_id = p_booking and kind in ('refund_share', 'chargeback_share') and status <> 'waived';
    v_delta := s.owner_payout_cents - v_pay - v_prior;
    if v_delta > 0 then
      insert into owner_deductions (owner_id, vehicle_id, kind, description, amount_cents, incurred_on, booking_id)
      values (s.owner_id, s.vehicle_id, case when v_chargeback > 0 then 'chargeback_share' else 'refund_share' end,
              format('Booking %s: Owner''s share of a later %s', b.booking_number,
                     case when v_chargeback > 0 then 'chargeback' else 'refund' end),
              v_delta, app.today(), p_booking);
    end if;
    update booking_splits set refunded_cents = v_refunded, chargeback_cents = v_chargeback, withheld_cents = v_withheld
     where booking_id = p_booking;
  else
    insert into booking_splits as bs (booking_id, vehicle_id, owner_id, referrer_type, referrer_owner_id, referrer_staff_id,
        is_first_rental, kickback_base_cents, kickback_cents, rental_charge_cents, mileage_overage_cents,
        owner_revenue_cents, company_share_bps, company_share_cents, owner_payout_cents, company_only_cents,
        pass_through_cents, hst_cents, collected_cents, refunded_cents, chargeback_cents, withheld_cents,
        uncollected_cents, kickback_ineligible_reason, counts_on, payout_month, status, computed_at)
    values (p_booking, b.vehicle_id, b.owner_id, b.referrer_type, b.referrer_owner_id, b.referrer_staff_id,
        v_reason is null, case when v_reason is null then v_rental else 0 end, v_kick, v_rental, v_mileage,
        v_rev, b.company_share_bps, v_share, v_pay, v_company,
        v_pass, v_hst, v_collected, v_refunded, v_chargeback, v_withheld,
        v_uncollected, v_reason, v_counts, app.month_start(v_counts),
        case when b.status in ('closed', 'cancelled', 'no_show') then 'final' else 'provisional' end, now())
    on conflict (booking_id) do update set
        vehicle_id = excluded.vehicle_id, owner_id = excluded.owner_id, referrer_type = excluded.referrer_type,
        referrer_owner_id = excluded.referrer_owner_id, referrer_staff_id = excluded.referrer_staff_id,
        is_first_rental = excluded.is_first_rental, kickback_base_cents = excluded.kickback_base_cents,
        kickback_cents = excluded.kickback_cents, rental_charge_cents = excluded.rental_charge_cents,
        mileage_overage_cents = excluded.mileage_overage_cents, owner_revenue_cents = excluded.owner_revenue_cents,
        company_share_bps = excluded.company_share_bps, company_share_cents = excluded.company_share_cents,
        owner_payout_cents = excluded.owner_payout_cents, company_only_cents = excluded.company_only_cents,
        pass_through_cents = excluded.pass_through_cents, hst_cents = excluded.hst_cents,
        collected_cents = excluded.collected_cents, refunded_cents = excluded.refunded_cents,
        chargeback_cents = excluded.chargeback_cents, withheld_cents = excluded.withheld_cents,
        uncollected_cents = excluded.uncollected_cents, kickback_ineligible_reason = excluded.kickback_ineligible_reason,
        counts_on = excluded.counts_on, payout_month = excluded.payout_month, status = excluded.status,
        computed_at = now();
  end if;

  -- the kickback record: pending until the rental is completed, reversed if it stops qualifying
  if v_kick > 0 then
    insert into referral_kickbacks as k (booking_id, renter_id, vehicle_id, referrer_type, referrer_owner_id, referrer_staff_id,
        base_cents, rate_bps, amount_cents, status, earned_on)
    values (p_booking, b.renter_id, b.vehicle_id, b.referrer_type, b.referrer_owner_id, b.referrer_staff_id,
        v_rental, v_set.kickback_bps, v_kick, case when v_done then 'earned' else 'pending' end,
        case when v_done then v_counts end)
    on conflict (booking_id) do update set
        base_cents = excluded.base_cents, amount_cents = excluded.amount_cents,
        status = case when k.status = 'paid' then 'paid' else excluded.status end,
        earned_on = coalesce(k.earned_on, excluded.earned_on)
      where k.status <> 'paid' or k.amount_cents = excluded.amount_cents;
  else
    -- reversed if the rental is refunded or charged back
    with rev as (
      update referral_kickbacks k
         set status = 'reversed', reversed_at = now(), reversal_reason = coalesce(v_reason, 'rental refunded or charged back')
       where k.booking_id = p_booking and k.status <> 'reversed'
      returning k.*, (select o.status from referral_kickbacks o where o.id = k.id) as was
    )
    insert into owner_deductions (owner_id, kind, description, amount_cents, incurred_on, booking_id)
    select rev.referrer_owner_id, 'kickback_reversal',
           format('Booking %s: Referral Kickback reversed', b.booking_number), rev.amount_cents, app.today(), p_booking
      from rev where rev.was = 'paid' and rev.referrer_owner_id is not null and rev.amount_cents > 0;
  end if;
end $$;

-- ---------------------------------------------------------------- the request flow (server only)
create sequence booking_number_seq start 10001;

-- A renter asks for a car. No payment, no card, nothing blocked. Priced from the rate card in
-- force now; staff adjust it afterwards. Also the staff path (phone, email, WhatsApp) and the
-- path for an Owner Booking. Returns the booking's id.
create or replace function app.request_booking(
  p_renter uuid, p_vehicle uuid, p_pickup timestamptz, p_return timestamptz,
  p_booking_type booking_type default 'standard', p_note text default null, p_source text default 'web',
  p_created_by uuid default null, p_referred_by text default null, p_promo_code text default null,
  p_pickup_method text default 'collected', p_return_method text default 'returned',
  p_pickup_place text default null, p_return_place text default null)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid := gen_random_uuid();
  v_set program_settings := app.settings();
  rc rate_cards;
  v_days integer;
  v_rate record;
  v_owner boolean := p_booking_type = 'owner';
  v_rental bigint;
  v_number text := 'CC-' || nextval('booking_number_seq');
begin
  if p_return is null or p_pickup is null or p_return <= p_pickup then
    raise exception 'The return must be after the pickup' using errcode = '22023';
  end if;
  select * into rc from rate_cards r
   where r.vehicle_id = p_vehicle and r.effective_from <= now() and (r.effective_to is null or r.effective_to > now());
  if rc.id is null and not v_owner then
    raise exception 'This vehicle has no rates set' using errcode = '23514';
  end if;
  v_days := public.calc_billable_days(p_pickup, p_return);
  select * into v_rate from public.calc_rental_charge(p_pickup, v_days,
      coalesce(rc.daily_rate_cents, 0), coalesce(rc.weekend_rate_cents, 0), coalesce(rc.weekly_rate_cents, 0), coalesce(rc.monthly_rate_cents, 0));
  v_rental := case when v_owner then 0 else v_rate.rental_charge_cents end;

  insert into bookings (id, booking_number, booking_type, status, vehicle_id, renter_id, source, booked_at, requested_at, request_note,
      pickup_at, return_at, original_return_at, pickup_method, return_method, pickup_place, return_place, billable_days,
      rate_card_id, daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, rate_applied, daily_days, weekend_days,
      rental_charge_cents, discount_cents, km_allowance_per_day, km_allowance_total, overage_cents_per_km,
      deposit_cents, deductible_cents, hst_bps, referred_by_code, created_by)
  values (v_id, v_number, p_booking_type, 'requested', p_vehicle, p_renter, p_source, now(), now(), p_note,
      p_pickup, p_return, p_return, p_pickup_method, p_return_method, p_pickup_place, p_return_place, v_days,
      case when not v_owner then rc.id end,
      case when v_owner then 0 else rc.daily_rate_cents end, case when v_owner then 0 else rc.weekend_rate_cents end,
      case when v_owner then 0 else rc.weekly_rate_cents end, case when v_owner then 0 else rc.monthly_rate_cents end,
      case when v_owner then 'none' else v_rate.rate_applied end, v_rate.daily_days, v_rate.weekend_days,
      v_rental,
      case when p_booking_type = 'non_refundable' then public.calc_bps(v_rental, v_set.non_refundable_discount_bps) else 0 end,
      coalesce(rc.km_allowance_per_day, 0), coalesce(rc.km_allowance_per_day, 0) * v_days, coalesce(rc.overage_cents_per_km, 0),
      case when v_owner then 0 else rc.deposit_cents end, v_set.deductible_cents, v_set.hst_bps, p_referred_by, p_created_by);

  perform app.reprice_booking(v_id);
  perform app.log_booking_event(v_id, 'requested', null, 'requested', null, p_note, p_created_by,
    case when p_created_by is not null and app.user_is_staff(p_created_by) and not app.is_booking_renter(v_id, p_created_by)
         then 'staff' else 'renter' end);
  if p_promo_code is not null then
    perform app.apply_promo_code(v_id, p_promo_code, p_created_by);
  end if;
  insert into tasks (queue, task_type, title, detail, procedure_no, booking_id, vehicle_id, renter_id)
  values ('cs', 'booking_request', format('New booking request %s', v_number),
          'Review the request, contact the customer if needed, adjust it and send an offer, or decline it.', 1, v_id, p_vehicle, p_renter);
  return v_id;
end $$;

-- Staff adjust a request before offering it: vehicle, dates and times, rates, rental charge,
-- discount, Deposit, mileage, delivery or pickup, notes, who the bill goes to. p_changes is a
-- JSON object of the columns to change; everything that follows from them (billable days, rate
-- applied, rental charge, non-refundable discount, mileage total, price lines, totals) is
-- worked out again. Moving to another vehicle takes that vehicle's rates unless rates are given.
-- A staff discount, or a rental charge typed by hand, is an Admin's decision.
-- Also used to correct the dates of a confirmed booking whose dates are marked provisional.
create or replace function app.adjust_booking(p_booking uuid, p_by uuid, p_changes jsonb, p_note text default null)
returns void language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  rc rate_cards;
  k text;
  v_set program_settings;
  v_allowed constant text[] := array['vehicle_id', 'pickup_at', 'return_at', 'booking_type',
    'daily_rate_cents', 'weekend_rate_cents', 'weekly_rate_cents', 'monthly_rate_cents', 'rental_charge_cents',
    'staff_discount_cents', 'staff_discount_reason', 'deposit_cents', 'km_allowance_per_day', 'overage_cents_per_km',
    'pickup_method', 'return_method', 'pickup_place', 'return_place', 'notes',
    'bill_to', 'insurer_id', 'insurer_claim_number', 'insurer_adjuster_name', 'insurer_adjuster_email', 'insurer_adjuster_phone',
    'insurer_authorized_daily_rate_cents', 'insurer_authorized_days', 'insurer_authorized_until', 'dates_provisional'];
  v_after_confirm constant text[] := array['pickup_at', 'return_at', 'dates_provisional', 'notes',
    'insurer_claim_number', 'insurer_adjuster_name', 'insurer_adjuster_email', 'insurer_adjuster_phone',
    'insurer_authorized_daily_rate_cents', 'insurer_authorized_days', 'insurer_authorized_until'];
  v_vehicle uuid; v_pickup timestamptz; v_return timestamptz; v_type booking_type;
  v_daily bigint; v_weekend bigint; v_weekly bigint; v_monthly bigint;
  v_km integer; v_over integer; v_deposit bigint; v_card uuid;
  v_days integer; v_rate record; v_rental bigint; v_discount bigint; v_staff bigint;
  v_owner boolean; v_confirmed boolean;
begin
  if not app.user_is_staff(p_by) then
    raise exception 'Only staff adjust a booking request' using errcode = '42501';
  end if;
  if p_changes is null or jsonb_typeof(p_changes) <> 'object' then
    raise exception 'Give the changes as a JSON object' using errcode = '22023';
  end if;
  select * into b from bookings where id = p_booking for update;
  if b.id is null then raise exception 'Booking % not found', p_booking; end if;
  v_confirmed := b.status in ('confirmed', 'on_rent') and b.dates_provisional;
  if b.status in ('offered', 'pending_payment') then
    raise exception 'An offer has been sent: withdraw it (back to requested) before changing its terms' using errcode = '23514';
  elsif not (b.status = 'requested' or v_confirmed) then
    raise exception 'Booking % is % and can no longer be adjusted here', b.booking_number, b.status using errcode = '23514';
  end if;
  for k in select jsonb_object_keys(p_changes) loop
    if not k = any (v_allowed) then
      raise exception 'Unknown change "%"', k using errcode = '22023';
    end if;
    if v_confirmed and not k = any (v_after_confirm) then
      raise exception 'On a confirmed booking with provisional dates only the dates and the insurer''s authorization can be corrected, not "%"', k
        using errcode = '23514';
    end if;
    if k in ('staff_discount_cents', 'rental_charge_cents') and not app.user_is_admin(p_by) then
      raise exception 'Only an Admin gives a discount or sets the rental charge by hand' using errcode = '42501';
    end if;
  end loop;

  v_set := app.settings(app.local_date(b.booked_at));
  v_vehicle := coalesce((p_changes ->> 'vehicle_id')::uuid, b.vehicle_id);
  v_pickup := coalesce((p_changes ->> 'pickup_at')::timestamptz, b.pickup_at);
  v_return := coalesce((p_changes ->> 'return_at')::timestamptz, b.return_at);
  v_type := coalesce((p_changes ->> 'booking_type')::booking_type, b.booking_type);
  v_owner := v_type = 'owner';
  v_daily := b.daily_rate_cents; v_weekend := b.weekend_rate_cents; v_weekly := b.weekly_rate_cents; v_monthly := b.monthly_rate_cents;
  v_km := b.km_allowance_per_day; v_over := b.overage_cents_per_km; v_deposit := b.deposit_cents; v_card := b.rate_card_id;
  if v_vehicle <> b.vehicle_id or (b.booking_type = 'owner' and not v_owner) then
    -- another vehicle (or no longer an Owner Booking): start from that vehicle's rate card
    select * into rc from rate_cards r
     where r.vehicle_id = v_vehicle and r.effective_from <= now() and (r.effective_to is null or r.effective_to > now());
    if rc.id is null and not v_owner then
      raise exception 'The vehicle has no rates set' using errcode = '23514';
    end if;
    if rc.id is not null then
      v_daily := rc.daily_rate_cents; v_weekend := rc.weekend_rate_cents; v_weekly := rc.weekly_rate_cents; v_monthly := rc.monthly_rate_cents;
      v_km := rc.km_allowance_per_day; v_over := rc.overage_cents_per_km; v_deposit := rc.deposit_cents; v_card := rc.id;
    end if;
  end if;
  v_daily := coalesce((p_changes ->> 'daily_rate_cents')::bigint, v_daily);
  v_weekend := coalesce((p_changes ->> 'weekend_rate_cents')::bigint, v_weekend);
  v_weekly := coalesce((p_changes ->> 'weekly_rate_cents')::bigint, v_weekly);
  v_monthly := coalesce((p_changes ->> 'monthly_rate_cents')::bigint, v_monthly);
  v_km := coalesce((p_changes ->> 'km_allowance_per_day')::integer, v_km);
  v_over := coalesce((p_changes ->> 'overage_cents_per_km')::integer, v_over);
  v_deposit := coalesce((p_changes ->> 'deposit_cents')::bigint, v_deposit);
  if v_return <= v_pickup then
    raise exception 'The return must be after the pickup' using errcode = '22023';
  end if;
  v_days := public.calc_billable_days(v_pickup, v_return);
  if v_owner then
    v_daily := 0; v_weekend := 0; v_weekly := 0; v_monthly := 0; v_deposit := 0; v_card := null;
  end if;
  select * into v_rate from public.calc_rental_charge(v_pickup, v_days, v_daily, v_weekend, v_weekly, v_monthly);
  v_rental := case when v_owner then 0 else coalesce((p_changes ->> 'rental_charge_cents')::bigint, v_rate.rental_charge_cents) end;
  v_discount := case when v_type = 'non_refundable' then public.calc_bps(v_rental, v_set.non_refundable_discount_bps) else 0 end;
  v_staff := case when v_owner then 0 else coalesce((p_changes ->> 'staff_discount_cents')::bigint, b.staff_discount_cents) end;

  update bookings set
      vehicle_id = v_vehicle, booking_type = v_type, pickup_at = v_pickup, return_at = v_return,
      original_return_at = case when b.status = 'requested' then v_return else original_return_at end,
      billable_days = v_days, rate_card_id = v_card,
      daily_rate_cents = v_daily, weekend_rate_cents = v_weekend, weekly_rate_cents = v_weekly, monthly_rate_cents = v_monthly,
      rate_applied = case when v_owner then 'none' else v_rate.rate_applied end,
      daily_days = v_rate.daily_days, weekend_days = v_rate.weekend_days,
      rental_charge_cents = v_rental, discount_cents = v_discount,
      staff_discount_cents = v_staff,
      staff_discount_reason = case when v_staff = 0 then null
                                   else coalesce(p_changes ->> 'staff_discount_reason', staff_discount_reason, p_note) end,
      km_allowance_per_day = v_km, km_allowance_total = v_km * v_days, overage_cents_per_km = v_over, deposit_cents = v_deposit,
      pickup_method = coalesce(p_changes ->> 'pickup_method', pickup_method),
      return_method = coalesce(p_changes ->> 'return_method', return_method),
      pickup_place = case when p_changes ? 'pickup_place' then p_changes ->> 'pickup_place' else pickup_place end,
      return_place = case when p_changes ? 'return_place' then p_changes ->> 'return_place' else return_place end,
      notes = case when p_changes ? 'notes' then p_changes ->> 'notes' else notes end,
      bill_to = coalesce(p_changes ->> 'bill_to', bill_to),
      insurer_id = case when p_changes ? 'insurer_id' then (p_changes ->> 'insurer_id')::uuid else insurer_id end,
      insurer_claim_number = case when p_changes ? 'insurer_claim_number' then p_changes ->> 'insurer_claim_number' else insurer_claim_number end,
      insurer_adjuster_name = case when p_changes ? 'insurer_adjuster_name' then p_changes ->> 'insurer_adjuster_name' else insurer_adjuster_name end,
      insurer_adjuster_email = case when p_changes ? 'insurer_adjuster_email' then p_changes ->> 'insurer_adjuster_email' else insurer_adjuster_email end,
      insurer_adjuster_phone = case when p_changes ? 'insurer_adjuster_phone' then p_changes ->> 'insurer_adjuster_phone' else insurer_adjuster_phone end,
      insurer_authorized_daily_rate_cents = case when p_changes ? 'insurer_authorized_daily_rate_cents'
        then (p_changes ->> 'insurer_authorized_daily_rate_cents')::bigint else insurer_authorized_daily_rate_cents end,
      insurer_authorized_days = case when p_changes ? 'insurer_authorized_days'
        then (p_changes ->> 'insurer_authorized_days')::integer else insurer_authorized_days end,
      insurer_authorized_until = case when p_changes ? 'insurer_authorized_until'
        then (p_changes ->> 'insurer_authorized_until')::date else insurer_authorized_until end,
      dates_provisional = coalesce((p_changes ->> 'dates_provisional')::boolean, dates_provisional)
   where id = p_booking;

  if b.status = 'requested' or (p_changes ->> 'dates_provisional')::boolean is distinct from false then
    perform app.reprice_booking(p_booking);
  else
    -- the dates were just made final in this call: price them one last time
    update bookings set dates_provisional = true where id = p_booking;
    perform app.reprice_booking(p_booking);
    update bookings set dates_provisional = false where id = p_booking;
  end if;
  perform app.log_booking_event(p_booking, 'adjusted', b.status::text, b.status::text, b.current_offer_version, p_note, p_by, 'staff', p_changes);
end $$;

-- Write the next version of the offer from the booking as it stands, and put the booking in
-- "offered". Internal: called by send_offer and by apply_promo_code.
create or replace function app.issue_offer(p_booking uuid, p_sent_by uuid, p_message text, p_expires_at timestamptz)
returns integer language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v vehicles;
  v_version integer;
  v_expires timestamptz;
begin
  select * into b from bookings where id = p_booking for update;
  select * into v from vehicles where id = b.vehicle_id;
  v_expires := coalesce(p_expires_at, now() + make_interval(hours => (app.settings()).offer_expiry_hours));
  if v_expires <= now() then
    raise exception 'An offer must expire in the future' using errcode = '22023';
  end if;
  update booking_offers set status = 'superseded', responded_at = now()
   where booking_id = p_booking and status in ('sent', 'approved');
  select coalesce(max(version), 0) + 1 into v_version from booking_offers where booking_id = p_booking;

  insert into booking_offers (booking_id, version, sent_by, expires_at, message, vehicle_id, pickup_at, return_at, billable_days,
      rental_charge_cents, discount_cents, deposit_cents, subtotal_cents, hst_cents, total_cents, insurer_share_cents, renter_due_cents,
      terms, line_items)
  values (p_booking, v_version, p_sent_by, v_expires, p_message, b.vehicle_id, b.pickup_at, b.return_at, b.billable_days,
      b.rental_charge_cents, b.discount_cents + b.staff_discount_cents + b.promo_discount_cents, b.deposit_cents,
      b.subtotal_at_booking_cents, b.hst_at_booking_cents, b.total_due_at_booking_cents,
      b.insurer_share_cents + b.insurer_hst_cents, b.total_due_at_booking_cents - b.insurer_share_cents - b.insurer_hst_cents,
      jsonb_build_object(
        'booking_number', b.booking_number, 'booking_type', b.booking_type,
        'vehicle', jsonb_build_object('id', v.id, 'year', v.year, 'make', v.make, 'model', v.model, 'colour', v.colour),
        'pickup_at', b.pickup_at, 'return_at', b.return_at, 'billable_days', b.billable_days,
        'pickup_method', b.pickup_method, 'return_method', b.return_method, 'pickup_place', b.pickup_place, 'return_place', b.return_place,
        'daily_rate_cents', b.daily_rate_cents, 'weekend_rate_cents', b.weekend_rate_cents,
        'weekly_rate_cents', b.weekly_rate_cents, 'monthly_rate_cents', b.monthly_rate_cents,
        'rate_applied', b.rate_applied, 'daily_days', b.daily_days, 'weekend_days', b.weekend_days,
        'rental_charge_cents', b.rental_charge_cents, 'non_refundable_discount_cents', b.discount_cents,
        'staff_discount_cents', b.staff_discount_cents, 'promo_discount_cents', b.promo_discount_cents,
        'promo_code', (select pc.code from promo_codes pc where pc.id = b.promo_code_id),
        'km_allowance_per_day', b.km_allowance_per_day, 'km_allowance_total', b.km_allowance_total,
        'overage_cents_per_km', b.overage_cents_per_km, 'deposit_cents', b.deposit_cents, 'deductible_cents', b.deductible_cents,
        'hst_bps', b.hst_bps, 'bill_to', b.bill_to, 'dates_provisional', b.dates_provisional, 'blocks_calendar', b.blocks_calendar,
        'insurer', case when b.insurer_id is not null then jsonb_build_object(
            'id', b.insurer_id, 'name', (select i.name from insurers i where i.id = b.insurer_id),
            'claim_number', b.insurer_claim_number, 'authorized_daily_rate_cents', b.insurer_authorized_daily_rate_cents,
            'authorized_days', b.insurer_authorized_days, 'authorized_until', b.insurer_authorized_until,
            'share_cents', b.insurer_share_cents, 'hst_cents', b.insurer_hst_cents) end),
      coalesce((select jsonb_agg(jsonb_build_object('charge_type', li.charge_type, 'description', li.description,
                                                    'quantity', li.quantity, 'amount_cents', li.amount_cents, 'hst_cents', li.hst_cents)
                                 order by f.sort_order, li.created_at, li.id)
                  from booking_line_items li join fee_types f on f.code = li.charge_type
                 where li.booking_id = p_booking and li.stage = 'booking' and li.charged_to_renter and li.voided_at is null), '[]'::jsonb));

  update bookings set status = 'offered', current_offer_version = v_version, offer_expires_at = v_expires where id = p_booking;
  perform app.log_booking_event(p_booking, 'offer_sent', 'requested', 'offered', v_version, p_message, p_sent_by,
                                case when p_sent_by is null then 'system' else 'staff' end,
                                jsonb_build_object('expires_at', v_expires, 'total_cents', b.total_due_at_booking_cents));
  return v_version;
end $$;

-- Staff send the offer (or send it again after changes: the earlier version is kept, marked
-- superseded). p_expires_at overrides the standard expiry for this offer. Returns the version.
create or replace function app.send_offer(p_booking uuid, p_sent_by uuid, p_message text default null,
                                          p_expires_at timestamptz default null)
returns integer language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v vehicles;
begin
  if not app.user_is_staff(p_sent_by) then
    raise exception 'Only staff send an offer' using errcode = '42501';
  end if;
  select * into b from bookings where id = p_booking for update;
  if b.id is null then raise exception 'Booking % not found', p_booking; end if;
  if b.status not in ('requested', 'offered') then
    raise exception 'Booking % is %: an offer is sent on a request', b.booking_number, b.status using errcode = '23514';
  end if;
  select * into v from vehicles where id = b.vehicle_id;
  if b.booking_type <> 'owner' then
    if not coalesce(app.vehicle_bookable(b.vehicle_id), false) then
      raise exception 'Vehicle is not open for new bookings' using errcode = '23514';
    end if;
    if v.exit_date is not null and app.local_date(b.return_at) > v.exit_date then
      raise exception 'The booking would run past the vehicle''s Exit Date' using errcode = '23514';
    end if;
  end if;
  if b.blocks_calendar and not app.vehicle_is_available(b.vehicle_id, b.pickup_at, b.return_at, b.id) then
    raise exception 'The vehicle is not available for these dates: change the vehicle or the dates before sending the offer'
      using errcode = '23P01';
  end if;
  if b.status = 'offered' then
    -- sent again: the version that is out is replaced, not withdrawn
    update booking_offers set status = 'superseded', responded_at = now() where booking_id = p_booking and status = 'sent';
    update bookings set status = 'requested' where id = p_booking;
  end if;
  perform app.reprice_booking(p_booking);
  return app.issue_offer(p_booking, p_sent_by, p_message, p_expires_at);
end $$;

-- The renter approves the offer they were shown (or staff record the approval the renter gave
-- them). A version that is no longer the current one is refused, and so is an expired one.
-- p_now is the instant to judge the expiry by (now, unless a test passes another).
create or replace function app.approve_offer(p_booking uuid, p_version integer, p_by uuid, p_now timestamptz default now())
returns void
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  o booking_offers;
  v_total bigint;
begin
  select * into b from bookings where id = p_booking for update;
  if b.id is null then raise exception 'Booking % not found', p_booking; end if;
  if p_by is null or not (app.is_booking_renter(p_booking, p_by) or app.user_is_staff(p_by)) then
    raise exception 'Only the renter of this booking, or staff on their word, approves an offer' using errcode = '42501';
  end if;
  if b.status <> 'offered' then
    raise exception 'There is no open offer on booking %', b.booking_number using errcode = '23514';
  end if;
  if p_version is distinct from b.current_offer_version then
    raise exception 'Offer version % has been replaced: the current offer is version %', p_version, b.current_offer_version
      using errcode = '23514';
  end if;
  select * into o from booking_offers where booking_id = p_booking and version = p_version;
  if o.status <> 'sent' or o.expires_at <= p_now then
    raise exception 'This offer has expired' using errcode = '23514';
  end if;
  select coalesce(sum(amount_cents + hst_cents), 0) into v_total from booking_line_items
   where booking_id = p_booking and stage = 'booking' and charged_to_renter and voided_at is null;
  if v_total <> o.total_cents then
    raise exception 'The charges on this booking changed after the offer was sent: a new offer is needed' using errcode = '23514';
  end if;
  if b.blocks_calendar and not app.vehicle_is_available(b.vehicle_id, b.pickup_at, b.return_at, b.id) then
    raise exception 'The vehicle is no longer available for these dates' using errcode = '23P01';
  end if;
  update booking_offers set status = 'approved', responded_at = p_now, responded_by = p_by where id = o.id;
  update bookings set status = 'pending_payment', offer_approved_version = p_version, offer_approved_at = p_now, offer_approved_by = p_by
   where id = p_booking;
  perform app.log_booking_event(p_booking, 'offer_approved', 'offered', 'pending_payment', p_version, null, p_by);
end $$;

-- Shared by the three ways an offer comes back to staff or ends.
create or replace function app.close_offer(p_booking uuid, p_by uuid, p_note text, p_offer_status text, p_to booking_status,
                                           p_kind text, p_staff_only boolean)
returns void language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
begin
  select * into b from bookings where id = p_booking for update;
  if b.id is null then raise exception 'Booking % not found', p_booking; end if;
  if p_by is null or not (app.user_is_staff(p_by) or (not p_staff_only and app.is_booking_renter(p_booking, p_by))) then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if not (b.status in ('offered', 'pending_payment') or (p_to = 'declined' and b.status = 'requested')) then
    raise exception 'Booking % is %: there is nothing here to %', b.booking_number, b.status,
      case p_kind when 'declined' then 'decline' when 'change_requested' then 'change' else 'withdraw' end using errcode = '23514';
  end if;
  if b.status = 'pending_payment' and exists (
       select 1 from payments p where p.booking_id = p_booking and p.purpose = 'booking_total' and p.kind = 'charge' and p.status = 'succeeded') then
    raise exception 'Booking % has already been paid: refund the payment first', b.booking_number using errcode = '23514';
  end if;
  update booking_offers set status = p_offer_status, responded_at = now(), responded_by = p_by, response_note = p_note
   where booking_id = p_booking and status in ('sent', 'approved');
  update bookings
     set status = p_to,
         request_note = case when p_kind = 'change_requested' then p_note else request_note end
   where id = p_booking;
  perform app.log_booking_event(p_booking, p_kind, b.status::text, p_to::text, b.current_offer_version, p_note, p_by);
end $$;

-- The renter asks for a change: back to requested, with their note, for staff to send a new offer.
create or replace function app.request_offer_change(p_booking uuid, p_by uuid, p_note text) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
begin
  if btrim(coalesce(p_note, '')) = '' then
    raise exception 'Say what should change' using errcode = '22023';
  end if;
  perform app.close_offer(p_booking, p_by, p_note, 'change_requested', 'requested', 'change_requested', false);
  select * into b from bookings where id = p_booking;
  insert into tasks (queue, task_type, title, detail, procedure_no, booking_id, vehicle_id, renter_id)
  values ('cs', 'offer_change_requested', format('Booking %s: the customer asked for a change', b.booking_number), p_note, 1,
          p_booking, b.vehicle_id, b.renter_id);
end $$;

-- The renter declines the offer or withdraws the request; or CarmaCars refuses it.
create or replace function app.decline_booking_request(p_booking uuid, p_by uuid, p_note text default null) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.close_offer(p_booking, p_by, p_note, 'declined', 'declined', 'declined', false);
end $$;

-- Staff take an offer back to change it.
create or replace function app.withdraw_offer(p_booking uuid, p_by uuid, p_note text default null) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.close_offer(p_booking, p_by, p_note, 'withdrawn', 'requested', 'offer_withdrawn', true);
end $$;

-- The calendar switch, with who and why. Turning it on runs the same overlap check as
-- confirmation (in app.booking_before_write) and sends competing offers back to staff.
create or replace function app.set_blocks_calendar(p_booking uuid, p_blocks boolean, p_by uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  if not app.user_is_staff(p_by) then
    raise exception 'Only staff change the calendar switch' using errcode = '42501';
  end if;
  update bookings set blocks_calendar = p_blocks, blocks_calendar_changed_by = p_by, blocks_calendar_reason = p_reason
   where id = p_booking and blocks_calendar is distinct from p_blocks;
end $$;

-- Offers not answered in time go back to requested (not to expired: the request and everything
-- staff worked out stay in one place, and staff can send it again, change it or decline it).
-- Safe to run at any time and any number of times. Returns how many offers it expired.
create or replace function app.expire_offers(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  r record;
  n integer := 0;
begin
  for r in select b.id, b.booking_number, b.current_offer_version, b.vehicle_id, b.renter_id, b.offer_expires_at
             from bookings b
            where b.status = 'offered' and b.offer_expires_at <= p_now
            order by b.offer_expires_at, b.id
            for update skip locked
  loop
    update booking_offers set status = 'expired', responded_at = p_now
     where booking_id = r.id and version = r.current_offer_version and status = 'sent';
    update bookings set status = 'requested' where id = r.id;
    perform app.log_booking_event(r.id, 'offer_expired', 'offered', 'requested', r.current_offer_version,
      format('Offer version %s was not answered by %s (Toronto). The request is back with staff.', r.current_offer_version,
             to_char(r.offer_expires_at at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI')), null, 'system');
    insert into tasks (queue, task_type, title, detail, procedure_no, booking_id, vehicle_id, renter_id)
    values ('cs', 'offer_expired', format('Booking %s: the offer expired without an answer', r.booking_number),
            'Follow up with the customer, then send the offer again, change it, or decline the request.', 1, r.id, r.vehicle_id, r.renter_id);
    n := n + 1;
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------- promo codes
-- Why a code cannot be used; null when it can. p_booking is the booking it would go on.
create or replace function app.promo_code_problem(p_code text, p_renter uuid, p_booking uuid default null,
                                                  p_at timestamptz default now())
returns text language plpgsql stable security definer set search_path = public, app as $$
declare
  pc promo_codes;
  b bookings;
begin
  select * into pc from promo_codes where code = upper(btrim(coalesce(p_code, '')));
  if pc.id is null then return 'This code is not known'; end if;
  if not pc.is_active then return 'This code is no longer active'; end if;
  if p_at < pc.valid_from then return 'This code is not valid yet'; end if;
  if pc.valid_until is not null and p_at >= pc.valid_until then return 'This code has expired'; end if;
  if pc.renter_id is not null and pc.renter_id is distinct from p_renter then return 'This code was issued to another customer'; end if;
  if pc.max_uses is not null and (select count(*) from promo_redemptions r
        where r.promo_code_id = pc.id and r.status in ('applied', 'redeemed')
          and (p_booking is null or r.booking_id <> p_booking)) >= pc.max_uses then
    return 'This code has been used up';
  end if;
  if pc.once_per_renter and exists (select 1 from promo_redemptions r
        where r.promo_code_id = pc.id and r.renter_id = p_renter and r.status in ('applied', 'redeemed')
          and (p_booking is null or r.booking_id <> p_booking)) then
    return 'This code has already been used by this customer';
  end if;
  if p_booking is not null then
    select * into b from bookings where id = p_booking;
    if b.booking_type = 'owner' or b.rental_charge_cents - b.discount_cents - b.staff_discount_cents <= 0 then
      return 'There is no rental charge to discount on this booking';
    end if;
  end if;
  return null;
end $$;

-- Check a code and put it on a request or an open offer. The discount comes off the rental
-- charge only (after any other discount), never off fees, the Deposit or tax. On an open offer a
-- new version is issued at once with the same expiry, so what the renter approves is the price
-- they see. Returns the discount in cents.
create or replace function app.apply_promo_code(p_booking uuid, p_code text, p_by uuid default null) returns bigint
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  pc promo_codes;
  v_problem text;
  v_was_offered boolean;
  v_expires timestamptz;
  v_discount bigint;
begin
  select * into b from bookings where id = p_booking for update;
  if b.id is null then raise exception 'Booking % not found', p_booking; end if;
  if b.status not in ('requested', 'offered') then
    raise exception 'A promo code goes on a request or an open offer; booking % is %', b.booking_number, b.status using errcode = '23514';
  end if;
  if p_by is not null and not (app.is_booking_renter(p_booking, p_by) or app.user_is_staff(p_by)) then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  select * into pc from promo_codes where code = upper(btrim(coalesce(p_code, ''))) for update;
  v_problem := app.promo_code_problem(p_code, b.renter_id, p_booking);
  if v_problem is not null then
    raise exception '%', v_problem using errcode = '23514';
  end if;
  v_was_offered := b.status = 'offered';
  v_expires := b.offer_expires_at;
  if v_was_offered and v_expires <= now() then
    raise exception 'This offer has expired' using errcode = '23514';
  end if;
  if v_was_offered then
    update booking_offers set status = 'superseded', responded_at = now() where booking_id = p_booking and status = 'sent';
    update bookings set status = 'requested' where id = p_booking;
  end if;
  update bookings set promo_code_id = pc.id where id = p_booking;
  insert into promo_redemptions as r (promo_code_id, booking_id, renter_id, discount_cents, status, applied_by)
  values (pc.id, p_booking, b.renter_id, 0, 'applied', p_by)
  on conflict (booking_id) do update
     set promo_code_id = excluded.promo_code_id, status = 'applied', applied_by = excluded.applied_by, applied_at = now(),
         released_at = null, redeemed_at = null;
  perform app.reprice_booking(p_booking);
  select promo_discount_cents into v_discount from bookings where id = p_booking;
  perform app.log_booking_event(p_booking, 'promo_applied', b.status::text, b.status::text, b.current_offer_version,
                                format('Promo code %s: %s cents off the rental charge', pc.code, v_discount), p_by);
  if v_was_offered then
    perform app.issue_offer(p_booking, null, format('Promo code %s applied', pc.code), v_expires);
  end if;
  return v_discount;
end $$;

-- Staff take a code off a request.
create or replace function app.remove_promo_code(p_booking uuid, p_by uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
begin
  if not app.user_is_staff(p_by) then
    raise exception 'Only staff remove a promo code' using errcode = '42501';
  end if;
  select * into b from bookings where id = p_booking for update;
  if b.status <> 'requested' then
    raise exception 'Withdraw the offer (back to requested) before removing the code' using errcode = '23514';
  end if;
  update promo_redemptions set status = 'released', released_at = now(), discount_cents = 0 where booking_id = p_booking and status = 'applied';
  update bookings set promo_discount_cents = 0, promo_code_id = null where id = p_booking;
  perform app.reprice_booking(p_booking);
  perform app.log_booking_event(p_booking, 'promo_removed', b.status::text, b.status::text, b.current_offer_version, null, p_by);
end $$;

-- ---------------------------------------------------------------- reviews
-- The renter of a closed booking leaves one review. It waits as "pending" until staff publish it.
create or replace function app.submit_review(p_booking uuid, p_by uuid, p_rating integer, p_title text default null,
                                             p_body text default null)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_id uuid;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null then raise exception 'Booking % not found', p_booking; end if;
  if p_by is null or not app.is_booking_renter(p_booking, p_by) then
    raise exception 'Only the renter of a booking may review it' using errcode = '42501';
  end if;
  if exists (select 1 from reviews where booking_id = p_booking) then
    raise exception 'This booking has already been reviewed' using errcode = '23505';
  end if;
  insert into reviews (booking_id, renter_id, vehicle_id, rating, title, body)
  values (p_booking, b.renter_id, b.vehicle_id, p_rating, nullif(btrim(p_title), ''), nullif(btrim(p_body), ''))
  returning id into v_id;
  return v_id;
end $$;

-- Published reviews, for anyone. The reviewer appears as a first name and the month of the
-- review, nothing more.
create or replace function app.public_reviews(p_vehicle uuid default null, p_limit integer default 20, p_offset integer default 0)
returns table (review_id uuid, vehicle_id uuid, vehicle_label text, rating smallint, title text, body text,
               reviewer_first_name text, review_month date, staff_reply text)
language sql stable security definer set search_path = public, app as $$
  select rv.id, rv.vehicle_id, v.year || ' ' || v.make || ' ' || v.model, rv.rating, rv.title, rv.body,
         split_part(btrim(r.legal_name), ' ', 1), app.month_start(app.local_date(rv.created_at)), rv.staff_reply
    from reviews rv
    join renters r on r.id = rv.renter_id
    join vehicles v on v.id = rv.vehicle_id
   where rv.status = 'published' and (p_vehicle is null or rv.vehicle_id = p_vehicle)
   order by rv.published_at desc, rv.id
   limit least(greatest(coalesce(p_limit, 20), 1), 100) offset greatest(coalesce(p_offset, 0), 0)
$$;

-- ---------------------------------------------------------------- insurer invoices
-- Draft (or refresh the draft of) the invoice for the insurer's part of a booking, less what
-- earlier invoices on the booking already billed. Returns the invoice id.
create or replace function app.draft_insurer_invoice(p_booking uuid, p_by uuid default null) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  s record;
  v_billed bigint; v_billed_hst bigint;
  v_amount bigint; v_hst bigint;
  v_end date;
  v_lines jsonb;
  v_id uuid;
begin
  select * into b from bookings where id = p_booking for update;
  if b.id is null then raise exception 'Booking % not found', p_booking; end if;
  if b.bill_to = 'renter' or b.insurer_id is null then
    raise exception 'Booking % is not billed to an insurer', b.booking_number using errcode = '23514';
  end if;
  if b.status not in ('confirmed', 'on_rent', 'returned', 'closed') then
    raise exception 'Booking % is %: an insurer is invoiced for a confirmed booking', b.booking_number, b.status using errcode = '23514';
  end if;
  select * into s from app.booking_insurer_share(p_booking);
  select coalesce(sum(amount_cents), 0), coalesce(sum(hst_cents), 0) into v_billed, v_billed_hst
    from insurer_invoices where booking_id = p_booking and status <> 'draft';
  v_amount := s.share_cents - v_billed;
  v_hst := s.hst_cents - v_billed_hst;
  if v_amount <= 0 then
    raise exception 'Nothing is left to invoice to the insurer on booking %', b.booking_number using errcode = '23514';
  end if;
  v_end := app.local_date(b.pickup_at + make_interval(days => s.covered_days));
  v_lines := jsonb_build_array(jsonb_build_object(
               'description', format('Rental charge, booking %s, %s day(s) authorized', b.booking_number, s.covered_days),
               'amount_cents', s.rental_share_cents))
             || case when s.fees_share_cents > 0 then jsonb_build_array(jsonb_build_object(
                  'description', 'Fees charged at booking', 'amount_cents', s.fees_share_cents)) else '[]'::jsonb end
             || case when v_billed > 0 then jsonb_build_array(jsonb_build_object(
                  'description', 'Less: already invoiced', 'amount_cents', -v_billed)) else '[]'::jsonb end;

  select id into v_id from insurer_invoices where booking_id = p_booking and status = 'draft';
  if v_id is null then
    insert into insurer_invoices (booking_id, insurer_id, claim_number, period_start, period_end, amount_cents, hst_cents, lines, created_by)
    values (p_booking, b.insurer_id, b.insurer_claim_number, app.local_date(b.pickup_at), greatest(v_end, app.local_date(b.pickup_at)),
            v_amount, greatest(v_hst, 0), v_lines, p_by)
    returning id into v_id;
  else
    update insurer_invoices
       set insurer_id = b.insurer_id, claim_number = b.insurer_claim_number, period_start = app.local_date(b.pickup_at),
           period_end = greatest(v_end, app.local_date(b.pickup_at)), amount_cents = v_amount, hst_cents = greatest(v_hst, 0), lines = v_lines
     where id = v_id;
  end if;
  return v_id;
end $$;

-- Record money received from an insurer against a sent invoice. It becomes a payment on the
-- booking (so the books show everything collected), and once an invoice on a booking billed
-- wholly to the insurer is paid in full, the booking's unpaid Owner Revenue lines are tied to
-- that payment, which is what lets the rental reach the Owner's statement.
create or replace function app.record_insurer_payment(p_invoice uuid, p_amount_cents bigint, p_by uuid default null,
    p_method text default 'bank_transfer', p_paid_at timestamptz default now(), p_reference text default null)
returns text language plpgsql security definer set search_path = public, app as $$
declare
  i insurer_invoices;
  b bookings;
  v_pay uuid;
  v_paid bigint;
  v_status text;
begin
  select * into i from insurer_invoices where id = p_invoice for update;
  if i.id is null then raise exception 'Invoice % not found', p_invoice; end if;
  if i.status not in ('sent', 'part_paid') then
    raise exception 'Invoice % is %: a payment is recorded on a sent invoice', i.invoice_number, i.status using errcode = '23514';
  end if;
  if p_amount_cents is null or p_amount_cents <= 0 or p_amount_cents > i.balance_cents then
    raise exception 'The payment must be more than nil and no more than the balance of %', i.balance_cents using errcode = '23514';
  end if;
  select * into b from bookings where id = i.booking_id;
  insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, processed_at, created_by)
  values (i.booking_id, b.renter_id, 'other', 'charge', p_method, p_amount_cents, 'succeeded', p_paid_at, p_by)
  returning id into v_pay;
  v_paid := i.paid_cents + p_amount_cents;
  v_status := case when v_paid = i.total_cents then 'paid' else 'part_paid' end;
  update insurer_invoices
     set paid_cents = v_paid, status = v_status, paid_at = case when v_status = 'paid' then p_paid_at end,
         last_payment_reference = coalesce(p_reference, last_payment_reference)
   where id = p_invoice;
  if v_status = 'paid' and b.bill_to = 'insurer' then
    update booking_line_items
       set payment_id = v_pay
     where booking_id = i.booking_id and payment_id is null and voided_at is null and charged_to_renter
       and stage in ('booking', 'extension') and revenue_class = 'owner_revenue';
    if b.status in ('returned', 'closed') then
      perform app.compute_booking_split(i.booking_id);
    end if;
  end if;
  return v_status;
end $$;

-- ---------------------------------------------------------------- the scheduled job
-- Replaces the "holds-expire" job that migration 0015 listed as not written: there are no
-- holds to expire any more. Every 5 minutes; does nothing, and records nothing, when no offer
-- is due. A run that does expire offers is recorded in job_runs under the minute it ran.
create or replace function app.job_offers_expire(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  v_run uuid;
  v_n integer;
begin
  if not exists (select 1 from bookings b where b.status = 'offered' and b.offer_expires_at <= p_now) then
    return 'not_due';
  end if;
  v_run := app.job_claim('offers-expire', to_char(p_now at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI"Z"'));
  if v_run is null then return 'already_run'; end if;
  begin
    v_n := app.expire_offers(p_now);
    perform app.job_succeed(v_run, jsonb_build_object('offers_expired', v_n));
    return 'succeeded';
  exception when others then
    perform app.job_fail(v_run, sqlerrm);
    return 'failed';
  end;
end $$;

-- ---------------------------------------------------------------- views
-- A renter's own bookings. As in migration 0012, with the request, the offer and who pays added at the end.
create or replace view renter_bookings with (security_barrier = true) as
  select b.id, b.booking_number, b.agreement_number, b.booking_type, b.renews_booking_id, b.status,
         b.vehicle_id, v.year as vehicle_year, v.make as vehicle_make, v.model as vehicle_model, v.colour as vehicle_colour,
         b.booked_at, b.confirmed_at, b.pickup_at, b.return_at, b.original_return_at, b.pickup_place, b.return_place,
         b.pickup_method, b.return_method, b.billable_days, b.handed_over_at, b.checked_in_at,
         b.daily_rate_cents, b.weekend_rate_cents, b.weekly_rate_cents, b.monthly_rate_cents, b.rate_applied,
         b.daily_days, b.weekend_days, b.rental_charge_cents, b.discount_cents,
         b.km_allowance_per_day, b.km_allowance_total, b.overage_cents_per_km, b.deposit_cents, b.deductible_cents,
         b.subtotal_at_booking_cents, b.hst_at_booking_cents, b.total_due_at_booking_cents,
         b.coverage_option, b.coverage_confirmed_at, b.odometer_out_km, b.odometer_in_km,
         b.fuel_out_pct, b.fuel_in_pct, b.minutes_late, b.extra_days, b.agreement_document_id,
         b.requested_at, b.request_note, b.current_offer_version, b.offer_expires_at, b.offer_approved_version, b.offer_approved_at,
         b.staff_discount_cents, b.promo_discount_cents, b.bill_to, b.dates_provisional,
         b.insurer_share_cents + b.insurer_hst_cents as insurer_pays_cents, b.renter_due_at_booking_cents
    from bookings b join vehicles v on v.id = b.vehicle_id
   where b.renter_id = app.my_renter_id();

-- An owner's view of bookings on their own vehicles. As in migration 0012, except that the
-- rental charge is shown after every discount, and a request or an offer (which may never
-- become a booking) is not listed, the same way a quote was not.
create or replace view owner_bookings with (security_barrier = true) as
  select b.id, b.booking_number, b.booking_type, b.status, b.vehicle_id, b.management_mode,
         b.pickup_at, b.return_at, b.pickup_place, b.return_place, b.billable_days,
         b.handed_over_at, b.checked_in_at,
         b.rental_charge_cents - b.discount_cents - b.staff_discount_cents - b.promo_discount_cents as rental_charge_cents,
         case when b.management_mode = 'self_managed' or b.booking_type = 'owner' then r.legal_name end as renter_name,
         case when b.management_mode = 'self_managed' or b.booking_type = 'owner' then r.mobile end as renter_mobile,
         s.mileage_overage_cents, s.kickback_cents, s.owner_revenue_cents, s.company_share_cents, s.owner_payout_cents,
         s.payout_month,
         b.blocks_calendar, b.dates_provisional
    from bookings b
    join renters r on r.id = b.renter_id
    left join booking_splits s on s.booking_id = b.id
   where app.is_my_owner(b.owner_id)
     and b.status::text not in ('requested', 'offered', 'tentative', 'expired', 'declined');

-- The master calendar's entries: every booking in every status, and every calendar block.
--   Admins and virtual assistants in customer service, finance or fleet see all of it.
--   A sales assistant sees every entry, with the renter's first name only.
--   An Owner sees the entries of their own vehicles, with the renter's first name only and no
--   insurer or internal note. Nobody else sees anything.
-- calendar_state: pending (requested, offered, waiting for signature and payment), booked
-- (confirmed), out (on rent), done (returned, closed), void (did not go ahead), blocked.
-- is_blocking is the one flag that says "this entry keeps the car".
create view calendar_entries with (security_barrier = true) as
  select 'booking'::text as entry_type, b.id as entry_id, b.vehicle_id,
         v.year || ' ' || v.make || ' ' || v.model as vehicle_label, v.plate, v.fleet_number,
         b.id as booking_id, b.booking_number, b.booking_type::text as booking_type, b.status::text as status,
         case when b.status::text in ('requested', 'offered', 'tentative', 'pending_payment') then 'pending'
              when b.status::text = 'confirmed' then 'booked'
              when b.status::text = 'on_rent' then 'out'
              when b.status::text in ('returned', 'closed') then 'done'
              else 'void' end as calendar_state,
         b.pickup_at as starts_at, b.return_at as ends_at,
         b.blocks_calendar,
         (b.blocks_calendar and b.status::text in ('confirmed', 'on_rent')) as is_blocking,
         b.bill_to, b.dates_provisional,
         case when app.is_admin() or app.va_has('cs', 'finance', 'fleet') then i.name end as insurer_name,
         case when app.is_admin() or app.va_has('cs', 'finance', 'fleet') then r.legal_name
              else split_part(btrim(r.legal_name), ' ', 1) end as renter_name,
         null::text as block_reason,
         case when app.is_admin() or app.va_has('cs', 'finance', 'fleet') then b.notes end as note
    from bookings b
    join vehicles v on v.id = b.vehicle_id
    join renters r on r.id = b.renter_id
    left join insurers i on i.id = b.insurer_id
   where app.is_staff() or app.owns_vehicle(b.vehicle_id)
  union all
  select 'block', c.id, c.vehicle_id,
         v.year || ' ' || v.make || ' ' || v.model, v.plate, v.fleet_number,
         null, null, null, 'blocked', 'blocked',
         c.starts_at, c.ends_at, true, true, null, false, null, null, c.reason,
         case when app.is_staff() then c.note end
    from vehicle_calendar_blocks c
    join vehicles v on v.id = c.vehicle_id
   where c.removed_at is null and (app.is_staff() or app.owns_vehicle(c.vehicle_id));

-- The master calendar for a date range: one row per entry that touches the range, and one row
-- with no entry for a vehicle that has none, so every vehicle the caller may see is on the
-- calendar. Vehicles that were declined or have left the program are not listed.
create or replace function app.master_calendar(p_from timestamptz, p_to timestamptz)
returns table (vehicle_id uuid, vehicle_label text, plate text, fleet_number text, vehicle_status text,
               entry_type text, entry_id uuid, booking_id uuid, booking_number text, booking_type text, status text,
               calendar_state text, starts_at timestamptz, ends_at timestamptz, blocks_calendar boolean, is_blocking boolean,
               bill_to text, dates_provisional boolean, insurer_name text, renter_name text, block_reason text, note text)
language sql stable security definer set search_path = public, app as $$
  select v.id, v.year || ' ' || v.make || ' ' || v.model, v.plate, v.fleet_number, v.status::text,
         e.entry_type, e.entry_id, e.booking_id, e.booking_number, e.booking_type, e.status,
         e.calendar_state, e.starts_at, e.ends_at, e.blocks_calendar, e.is_blocking,
         e.bill_to, e.dates_provisional, e.insurer_name, e.renter_name, e.block_reason, e.note
    from vehicles v
    left join calendar_entries e
      on e.vehicle_id = v.id and e.starts_at < p_to and (e.ends_at is null or e.ends_at > p_from)
   where (app.is_staff() or app.owns_vehicle(v.id))
     and v.status::text not in ('declined', 'exited')
   order by v.fleet_number nulls last, v.id, e.starts_at, e.entry_id
$$;

-- ---------------------------------------------------------------- who works on which renter
-- As in migration 0012, with requests and offers counted as live work.
create or replace function app.va_sees_renter(p_renter uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.is_va() and (
    -- a booking that is live, or ended within the window
    exists (select 1 from bookings b
             where b.renter_id = p_renter
               and (b.status::text in ('requested', 'offered', 'tentative', 'pending_payment', 'confirmed', 'on_rent', 'returned')
                    or greatest(b.return_at, coalesce(b.checked_in_at, b.return_at))
                       > now() - make_interval(days => (app.settings()).staff_customer_window_days)))
    -- an open task about this renter
    or exists (select 1 from tasks t where t.renter_id = p_renter and t.status in ('open', 'in_progress', 'waiting'))
    -- a new lead with no booking yet
    or exists (select 1 from renters r where r.id = p_renter
                and r.created_at > now() - make_interval(days => (app.settings()).staff_customer_window_days)
                and not exists (select 1 from bookings b where b.renter_id = r.id))
    -- a logged, time-limited lookup (app.staff_open_renter)
    or exists (select 1 from data_access_log g
                where g.renter_id = p_renter and g.user_id = app.uid() and g.action = 'open' and g.granted_until > now()))
$$;

-- ---------------------------------------------------------------- row-level security
do $$
declare
  t text;
begin
  foreach t in array array['insurers', 'promo_codes', 'promo_redemptions', 'booking_offers', 'booking_events', 'reviews', 'insurer_invoices'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy admin_all on public.%I for all to authenticated using (app.is_admin()) with check (app.is_admin())', t);
  end loop;
end $$;

-- bookings: the sales role works on requests and offers as it did on quotes; customer service
-- may enter a request. (Recreated because the old policies named only the old statuses.)
drop policy va_read on bookings;
drop policy cs_insert on bookings;
drop policy sales_insert on bookings;
drop policy sales_update on bookings;
create policy va_read on bookings for select to authenticated
  using (app.va_has('cs', 'finance', 'fleet')
         or (app.va_has('sales') and status::text in ('requested', 'offered', 'tentative', 'pending_payment')));
create policy cs_insert on bookings for insert to authenticated
  with check (app.va_has('cs') and status::text in ('requested', 'tentative', 'pending_payment'));
create policy sales_insert on bookings for insert to authenticated
  with check (app.va_has('sales') and status::text in ('requested', 'tentative'));
create policy sales_update on bookings for update to authenticated
  using (app.va_has('sales') and status::text in ('requested', 'tentative'))
  with check (app.va_has('sales') and status::text in ('requested', 'tentative'));

-- offers and the event log: written by the server only. The renter reads their own offers;
-- the event log holds staff notes and is for staff.
create policy renter_read on booking_offers for select to authenticated using (app.is_my_booking(booking_id));
create policy va_read on booking_offers for select to authenticated using (app.is_va());
create policy va_read on booking_events for select to authenticated using (app.is_va());

-- insurers: customer service and finance keep the list; every assistant may read it
create policy va_read on insurers for select to authenticated using (app.is_va());
create policy va_insert on insurers for insert to authenticated with check (app.va_has('cs', 'finance'));
create policy va_update on insurers for update to authenticated using (app.va_has('cs', 'finance')) with check (app.va_has('cs', 'finance'));

-- insurer invoices: finance reads them, corrects a draft and marks it sent. Amounts paid are
-- recorded by the server (app.record_insurer_payment); a write-off is an Admin's.
create policy finance_read on insurer_invoices for select to authenticated using (app.va_has('finance'));
create policy finance_update on insurer_invoices for update to authenticated
  using (app.va_has('finance') and status in ('draft', 'sent'))
  with check (app.va_has('finance') and status in ('draft', 'sent'));
create trigger insurer_invoices_guard_admin_columns before update on insurer_invoices
  for each row execute function app.guard_admin_columns('paid_cents', 'paid_at', 'booking_id', 'insurer_id', 'written_off_by');
create trigger insurer_invoices_guard_approver before insert or update on insurer_invoices
  for each row execute function app.guard_approver('sent_by', 'written_off_by');

-- promo codes: only an Admin (or the server, for the follow-up emails) creates one; the
-- assistants who quote and bill may read them
create policy va_read on promo_codes for select to authenticated using (app.va_has('cs', 'sales', 'finance'));
create policy renter_read on promo_redemptions for select to authenticated using (renter_id = app.my_renter_id());
create policy va_read on promo_redemptions for select to authenticated using (app.va_has('cs', 'sales', 'finance'));

-- reviews: the renter reads their own; customer service moderates (status and reply, never the
-- renter's words). Everyone else, the anonymous role included, reads app.public_reviews().
create policy renter_read on reviews for select to authenticated using (renter_id = app.my_renter_id());
create policy cs_read on reviews for select to authenticated using (app.va_has('cs'));
create policy cs_update on reviews for update to authenticated using (app.va_has('cs')) with check (app.va_has('cs'));
create trigger reviews_guard_admin_columns before update on reviews
  for each row execute function app.guard_admin_columns('rating', 'title', 'body');
create trigger reviews_guard_approver before update on reviews
  for each row execute function app.guard_approver('moderated_by', 'staff_reply_by');

-- calendar blocks: fleet and customer service already create and edit them (migration 0012).
-- Removing one is the same edit: set removed_at, with who.
create trigger calendar_blocks_guard_approver before insert or update on vehicle_calendar_blocks
  for each row execute function app.guard_approver('removed_by');

-- ---------------------------------------------------------------- privileges
revoke all on insurers, promo_codes, promo_redemptions, booking_offers, booking_events, reviews, insurer_invoices, calendar_entries
  from anon, authenticated;
grant select, insert, update on insurers, promo_codes, reviews, insurer_invoices to authenticated;
-- written by the server only
grant select on promo_redemptions, booking_offers, booking_events, calendar_entries to authenticated;
revoke insert on reviews, insurer_invoices from authenticated;
grant all on insurers, promo_codes, promo_redemptions, booking_offers, booking_events, reviews, insurer_invoices, calendar_entries
  to service_role;
grant usage on sequence insurer_invoice_number_seq, booking_number_seq to service_role;

-- Functions: closed to everyone, then opened one by one. Everything that changes a booking's
-- state, prices it, uses a promo code or records money is for the server alone.
revoke execute on function
  app.guard_booking_offer(), app.guard_review(), app.booking_request_after(),
  app.user_is_admin(uuid), app.user_is_staff(uuid), app.is_booking_renter(uuid, uuid),
  app.log_booking_event(uuid, text, text, text, integer, text, uuid, text, jsonb),
  app.vehicle_is_available(uuid, timestamptz, timestamptz, uuid), app.public_vehicle_calendar(uuid, date, date),
  app.booking_insurer_share(uuid), app.promo_discount_cents(uuid, bigint), app.set_price_line(uuid, text, bigint, integer),
  app.reprice_booking(uuid),
  app.request_booking(uuid, uuid, timestamptz, timestamptz, booking_type, text, text, uuid, text, text, text, text, text, text),
  app.adjust_booking(uuid, uuid, jsonb, text), app.issue_offer(uuid, uuid, text, timestamptz),
  app.send_offer(uuid, uuid, text, timestamptz), app.approve_offer(uuid, integer, uuid, timestamptz),
  app.close_offer(uuid, uuid, text, text, booking_status, text, boolean), app.request_offer_change(uuid, uuid, text),
  app.decline_booking_request(uuid, uuid, text), app.withdraw_offer(uuid, uuid, text),
  app.set_blocks_calendar(uuid, boolean, uuid, text), app.expire_offers(timestamptz),
  app.promo_code_problem(text, uuid, uuid, timestamptz), app.apply_promo_code(uuid, text, uuid), app.remove_promo_code(uuid, uuid),
  app.submit_review(uuid, uuid, integer, text, text), app.public_reviews(uuid, integer, integer),
  app.draft_insurer_invoice(uuid, uuid), app.record_insurer_payment(uuid, bigint, uuid, text, timestamptz, text),
  app.job_offers_expire(timestamptz), app.master_calendar(timestamptz, timestamptz)
  from public, anon, authenticated;
grant execute on all functions in schema app to service_role;
-- what a browser session may call: is the car free, the two calendars, the published reviews
grant execute on function app.vehicle_is_available(uuid, timestamptz, timestamptz, uuid),
  app.public_vehicle_calendar(uuid, date, date), app.public_reviews(uuid, integer, integer) to anon, authenticated;
grant execute on function app.master_calendar(timestamptz, timestamptz) to authenticated;

-- ---------------------------------------------------------------- audit
do $$ begin perform app.attach_audit(); end $$;

-- ---------------------------------------------------------------- the schedule (pg_cron)
-- Same pattern as migration 0015: nothing where pg_cron is absent.
do $$
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    raise notice 'pg_cron is not available here: no jobs scheduled';
    return;
  end if;
  begin
    create extension if not exists pg_cron;
  exception when others then
    raise warning 'pg_cron could not be created in this database (%): no jobs scheduled', sqlerrm;
    return;
  end;
  perform cron.schedule('carmacars-offers-expire', '*/5 * * * *', 'select app.job_offers_expire()');
end $$;
