-- 0164_referral_partners.sql
-- The owner's request of October 22-23, 2026 (docs/changes/2026-10-25-referral-partners.md): "referral programs for body shops
-- and tow trucks to refer renters (insurance replacement and accident renters), and a RentalCoverage affiliate program for a
-- kickback on policies renters buy there".
--
-- 1. Referral partners: a body shop, a tow truck company (and, as cheaply as the same table allows, a dealership or an
--    insurance broker) that sends us renters. Each has a short code (carmacars.ca/r/<CODE>, a QR code, a printable counter
--    flyer), a rate (a flat amount per completed rental, $50 by default, or a share of the rental charge) and a payout method.
--    The partner's code on a request (the link's cookie for 60 days, or typed in the request form) or on Add a rental ties
--    the booking to the partner (bookings.referral_partner_id). The kickback is earned when the rental is completed and paid in
--    full, on the rental charge after discounts (the same base as every staff commission, 0058), is approved by an Admin and
--    paid by hand, and it is a booking expense before Owner Revenue on a program owner's car (CarmaCars' own on a partner's or a
--    CarmaCars-owned car): the 0058 staff-commission deduction carries it (app.booking_staff_commission_cents adds it).
--    A partner has no sign-in: a link only they hold (an HMAC of the partner and the link's version, nothing secret stored)
--    shows their referrals (first name and month only) and earnings.
--    The public sign-up form on /partners/body-shops and /partners/tow-trucks makes a pending partner and a task for the
--    Admins; nothing is active until an Admin approves it.
-- 2. The RentalCoverage affiliate: one settings row (the affiliate link, or a link with {id} and the ID; off until set), the
--    clicks on it from the site (by place on the site, by visitor, by booking when known), and the payments RentalCoverage
--    makes to us, entered by hand (they report conversions, we do not see them). Nothing is claimed about the coverage.
-- 3. Admin: the doors (admin_read 'referral_partners', 'referral_partner', 'referral_earnings', 'coverage_affiliate';
--    admin_do 'referral_partner_save', 'referral_partner_decide', 'referral_partner_link_new', 'referral_partner_credit',
--    'referral_earning_approve', 'referral_earning_reverse', 'referral_partner_payout', 'coverage_affiliate_save',
--    'coverage_affiliate_payment_add').
-- 4. The guides.
-- No applied migration is edited. app.resolve_referrer (0016), app.booking_staff_commission_cents (0058), app.manual_rental_create
-- (0148) and app.door (0156) are replaced or wrapped here.

-- ================================================================ 1. settings
alter table program_settings
  add column if not exists referral_partner_flat_cents bigint not null default 5000 check (referral_partner_flat_cents between 0 and 100000),
  add column if not exists referral_partner_percent_bps integer not null default 1000 check (referral_partner_percent_bps between 0 and 5000);
comment on column program_settings.referral_partner_flat_cents is 'The flat kickback a new referral partner starts with, per completed rental (0164): $50 by default; each partner''s own rate is kept on the partner and changes nothing already earned';
comment on column program_settings.referral_partner_percent_bps is 'The share of the rental charge a new referral partner starts with when an Admin chooses a percentage instead of a flat amount (0164): 10% by default';

-- ================================================================ 2. referral partners
create table if not exists referral_partners (
  id             uuid primary key default gen_random_uuid(),
  kind           text not null check (kind in ('body_shop', 'tow_truck', 'dealership', 'insurance_broker')),
  status         text not null default 'active' check (status in ('pending', 'active', 'paused', 'ended', 'declined')),
  business_name  text not null check (length(btrim(business_name)) between 2 and 120),
  contact_name   text check (contact_name is null or length(contact_name) <= 120),
  phone          text check (phone is null or length(phone) <= 40),
  email          text check (email is null or email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  address_line1  text check (address_line1 is null or length(address_line1) <= 200),
  city           text check (city is null or length(city) <= 80),
  province       text check (province is null or length(province) <= 40),
  postal_code    text check (postal_code is null or length(postal_code) <= 12),
  payout_method  text not null default 'e_transfer' check (payout_method in ('e_transfer', 'cheque', 'bank_transfer', 'cash', 'other')),
  payout_email   text check (payout_email is null or payout_email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  rate_kind      text not null default 'flat' check (rate_kind in ('flat', 'percent')),
  flat_cents     bigint not null default 5000 check (flat_cents between 0 and 100000),
  rate_bps       integer not null default 1000 check (rate_bps between 0 and 5000),
  referral_code  text not null unique check (referral_code ~ '^[A-Z0-9]{4,12}$'),
  portal_version integer not null default 1 check (portal_version > 0),
  source         text not null default 'admin' check (source in ('admin', 'signup')),
  signup_note    text check (signup_note is null or length(signup_note) <= 1000),
  notes          text,
  decided_at     timestamptz,
  decided_by     uuid references users (id),
  created_by     uuid references users (id),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create trigger referral_partners_updated before update on referral_partners for each row execute function app.set_updated_at();
create index if not exists referral_partners_status_idx on referral_partners (status, created_at);
comment on table referral_partners is 'A business that sends us renters and earns a kickback per completed rental (0164): body shops, tow trucks, dealerships, insurance brokers. The code is the link (/r/<CODE>) and the code field; the link to their own page is made from portal_version';
comment on column referral_partners.rate_kind is 'flat: flat_cents per completed rental; percent: rate_bps of the rental charge after discounts. A booking keeps the rate the partner had when it was tied to them';
comment on column referral_partners.portal_version is 'Version of the partner''s private page link (an HMAC of the partner and this number, never stored): New link raises it and ends the old one';

alter table bookings add column if not exists referral_partner_id uuid references referral_partners (id);
create index if not exists bookings_referral_partner_idx on bookings (referral_partner_id) where referral_partner_id is not null;
comment on column bookings.referral_partner_id is 'The referral partner (body shop, tow truck, ...) whose code is on the booking (0164): earns a kickback when the rental is completed and paid; never together with an owner or field staff referral';
drop trigger if exists bookings_guard_referral_partner on bookings;
create trigger bookings_guard_referral_partner before update on bookings
  for each row execute function app.guard_admin_columns('referral_partner_id');

create table if not exists referral_partner_payouts (
  id            uuid primary key default gen_random_uuid(),
  partner_id    uuid not null references referral_partners (id),
  method        text not null check (method in ('e_transfer', 'cheque', 'bank_transfer', 'cash', 'other')),
  reference     text,
  paid_on       date not null,
  amount_cents  bigint not null check (amount_cents > 0),
  note          text,
  recorded_by   uuid not null references users (id),
  created_at    timestamptz not null default now(),
  check (method <> 'other' or nullif(btrim(coalesce(note, '')), '') is not null)
);
create index if not exists referral_partner_payouts_partner_idx on referral_partner_payouts (partner_id, paid_on);
comment on table referral_partner_payouts is 'A payment of approved referral kickbacks made by hand by an Admin (0164): method, reference, date. Never paid automatically';

create table if not exists referral_partner_earnings (
  id             uuid primary key default gen_random_uuid(),
  booking_id     uuid not null references bookings (id),
  partner_id     uuid not null references referral_partners (id),
  kind           text not null default 'earning' check (kind in ('earning', 'clawback')),
  clawback_of    uuid references referral_partner_earnings (id),
  rate_kind      text not null check (rate_kind in ('flat', 'percent')),
  flat_cents     bigint,
  rate_bps       integer,
  base_cents     bigint not null default 0,
  amount_cents   bigint not null default 0,
  status         text not null check (status in ('accruing', 'pending_approval', 'approved', 'paid', 'reversed', 'void')),
  reason         text,
  note           text,
  earned_at      timestamptz,
  approved_at    timestamptz,
  approved_by    uuid references users (id),
  payout_id      uuid references referral_partner_payouts (id),
  paid_at        timestamptz,
  reversed_at    timestamptz,
  reversed_by    uuid references users (id),
  admin_reversed boolean not null default false,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  check (kind = 'earning' or clawback_of is not null),
  check ((kind = 'clawback') = (amount_cents < 0) or (kind = 'earning' and amount_cents >= 0)),
  check ((status = 'paid') = (payout_id is not null))
);
create unique index if not exists referral_partner_earnings_one_idx on referral_partner_earnings (booking_id, partner_id) where kind = 'earning';
create index if not exists referral_partner_earnings_partner_idx on referral_partner_earnings (partner_id, status);
create index if not exists referral_partner_earnings_booking_idx on referral_partner_earnings (booking_id);
comment on table referral_partner_earnings is 'The ledger of referral kickbacks (0164): one earning per referred booking and partner, from accruing (the rental is not completed and paid yet) to pending approval, approved and paid, or reversed and void; a clawback (negative, approved) when a paid one stops being due, taken off the next payment';

-- ================================================================ 3. the RentalCoverage affiliate
create table if not exists coverage_affiliate (
  singleton    boolean primary key default true check (singleton),
  display_name text not null default 'RentalCoverage' check (length(btrim(display_name)) between 2 and 60),
  link_url     text check (link_url is null or link_url ~ '^https://[^[:space:]]+$'),
  affiliate_id text check (affiliate_id is null or length(affiliate_id) <= 120),
  enabled      boolean not null default false,
  updated_by   uuid references users (id),
  updated_at   timestamptz not null default now()
);
insert into coverage_affiliate (singleton) values (true) on conflict do nothing;
comment on table coverage_affiliate is 'The RentalCoverage affiliate program (0164): the tracking link from the affiliate dashboard (a {id} in it is replaced by the affiliate ID) and whether the site shows it. Off until a link is pasted; nothing is shown or claimed while it is off';

create table if not exists coverage_clicks (
  id          uuid primary key default gen_random_uuid(),
  clicked_at  timestamptz not null default now(),
  placement   text not null check (placement in ('requirements', 'card_guide', 'booking_step', 'booking_page', 'other')),
  visitor_id  uuid,
  booking_id  uuid references bookings (id) on delete set null
);
create index if not exists coverage_clicks_at_idx on coverage_clicks (clicked_at);
create index if not exists coverage_clicks_booking_idx on coverage_clicks (booking_id) where booking_id is not null;
comment on table coverage_clicks is 'A click on the RentalCoverage link from the site (0164): where on the site, the visitor''s cookie id and the booking when the visitor had one';

create table if not exists coverage_affiliate_payments (
  id            uuid primary key default gen_random_uuid(),
  received_on   date not null,
  amount_cents  bigint not null check (amount_cents > 0),
  period_note   text,
  reference     text,
  note          text,
  recorded_by   uuid not null references users (id),
  created_at    timestamptz not null default now()
);
comment on table coverage_affiliate_payments is 'What RentalCoverage paid CarmaCars as an affiliate (0164), entered by hand: they report the conversions, the site cannot see them';

do $$
declare t text;
begin
  foreach t in array array['referral_partners', 'referral_partner_payouts', 'referral_partner_earnings', 'coverage_affiliate', 'coverage_clicks', 'coverage_affiliate_payments'] loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on %I from anon, authenticated', t);
    execute format('grant select on %I to authenticated', t);
    execute format('grant all on %I to service_role', t);
    execute format('drop policy if exists admin_all on %I', t);
    execute format('create policy admin_all on %I for all to authenticated using (app.is_admin()) with check (app.is_admin())', t);
  end loop;
end $$;

-- ================================================================ 4. codes and attribution
-- A code nobody else holds (an owner's, a field staff member's, a partner's): six characters without the look-alikes.
create or replace function app.referral_code_free(p_code text) returns boolean
language sql stable security definer set search_path = public, app as $$
  select not exists (select 1 from owners where upper(referral_code) = upper(p_code))
     and not exists (select 1 from staff_profiles where upper(referral_code) = upper(p_code))
     and not exists (select 1 from referral_partners where referral_code = upper(p_code))
$$;
create or replace function app.referral_code_new() returns text
language plpgsql volatile security definer set search_path = public, app as $$
declare
  v_chars constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  v_code text;
  i integer;
begin
  loop
    v_code := '';
    for i in 1 .. 6 loop v_code := v_code || substr(v_chars, 1 + floor(random() * length(v_chars))::integer, 1); end loop;
    exit when app.referral_code_free(v_code);
  end loop;
  return v_code;
end $$;

-- The active partner holding a code (null when none).
create or replace function app.referral_partner_by_code(p_code text) returns uuid
language sql stable security definer set search_path = public, app as $$
  select id from referral_partners where referral_code = upper(btrim(coalesce(p_code, ''))) and status = 'active'
$$;
create or replace function public.referral_partner_code_ok(p_code text) returns boolean
language sql stable security definer set search_path = public, app as $$ select app.referral_partner_by_code(p_code) is not null $$;

-- 0016's resolve_referrer: an owner's or a field staff member's code as before; a code that is neither may be an active
-- referral partner's (the booking is tied to the partner, never to two referrers).
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
      elsif new.referral_partner_id is null and (tg_op = 'INSERT' or old.referred_by_code is distinct from new.referred_by_code) then
        new.referral_partner_id := app.referral_partner_by_code(new.referred_by_code);
      end if;
    end if;
  end if;
  -- virtual assistants earn no referral fee
  if new.referrer_staff_id is not null and not exists (
       select 1 from staff_profiles sp where sp.user_id = new.referrer_staff_id and sp.staff_type = 'field') then
    raise exception 'Only in-person field staff can be a staff referrer' using errcode = '23514';
  end if;
  if new.referral_partner_id is not null and new.referrer_type is not null then new.referral_partner_id := null; end if;
  return new;
end $$;

-- ================================================================ 5. the kickback: earned, approved, paid
-- What a rate comes to on a base: a flat amount or a share, never more than the base itself.
create or replace function app.referral_earning_amount(p_kind text, p_flat bigint, p_bps integer, p_base bigint) returns bigint
language sql immutable as $$
  select greatest(least(case when p_kind = 'flat' then coalesce(p_flat, 0) else round(coalesce(p_base, 0) * coalesce(p_bps, 0) / 10000.0) end, coalesce(p_base, 0)), 0)::bigint
$$;

-- The partner's kickbacks on a booking that count against the booking now (what is due on each; a paid one net of its clawback).
create or replace function app.booking_referral_partner_cents(p_booking uuid) returns bigint
language sql stable security definer set search_path = public, app as $$
  select greatest(coalesce(sum(e.amount_cents), 0), 0)::bigint from referral_partner_earnings e where e.booking_id = p_booking and e.status not in ('void', 'reversed')
$$;

-- 0058's deduction before Owner Revenue, with the referral partner's kickback in it (a program owner's car; a partner's or a
-- CarmaCars-owned car: CarmaCars pays it, as it pays a staff commission).
create or replace function app.booking_staff_commission_cents(p_booking uuid) returns bigint
language sql stable security definer set search_path = public, app as $$
  select greatest(coalesce(sum(c.amount_cents), 0), 0)::bigint + app.booking_referral_partner_cents(p_booking)
    from staff_commissions c where c.booking_id = p_booking and c.status not in ('void', 'reversed')
$$;

-- A kickback that stops being due: not earned yet or not paid, it is void or reversed; paid, a clawback (negative, approved)
-- is taken off the next payment.
create or replace function app.referral_earning_close(p_id uuid, p_reason text, p_by uuid default null) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  c referral_partner_earnings;
begin
  select * into c from referral_partner_earnings where id = p_id for update;
  if c.id is null or c.kind <> 'earning' or c.status in ('void', 'reversed') or c.reversed_at is not null then return; end if;
  if c.status = 'accruing' then
    update referral_partner_earnings set status = 'void', reason = p_reason, reversed_at = now(), reversed_by = p_by, updated_at = now() where id = c.id;
  elsif c.status in ('pending_approval', 'approved') then
    update referral_partner_earnings set status = 'reversed', reason = p_reason, reversed_at = now(), reversed_by = p_by, updated_at = now() where id = c.id;
  else
    update referral_partner_earnings set reason = p_reason, reversed_at = now(), reversed_by = p_by, updated_at = now() where id = c.id;
    if not exists (select 1 from referral_partner_earnings x where x.clawback_of = c.id and x.status <> 'void') then
      insert into referral_partner_earnings (booking_id, partner_id, kind, clawback_of, rate_kind, flat_cents, rate_bps, base_cents, amount_cents, status, reason, approved_at, approved_by)
      values (c.booking_id, c.partner_id, 'clawback', c.id, c.rate_kind, c.flat_cents, c.rate_bps, c.base_cents, -c.amount_cents, 'approved',
              'Taken back after payment: ' || p_reason, now(), p_by);
    end if;
  end if;
end $$;

-- Bring a booking's kickback in step with the booking: whether it is due, its base and amount, earned or not. Called by
-- the triggers below and by the functions that change the partner.
create or replace function app.referral_partner_sync(p_booking uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  c referral_partner_earnings;
  pr referral_partners;
  v_reason text;
  v_base bigint;
  v_earned boolean;
  v_amount bigint;
  v_before bigint;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null then return; end if;
  v_before := app.booking_referral_partner_cents(b.id);
  -- a credit that moved: the earlier partner's kickback stops
  for c in select * from referral_partner_earnings x where x.booking_id = b.id and x.kind = 'earning' and x.partner_id is distinct from b.referral_partner_id
             and x.status not in ('void', 'reversed') and x.reversed_at is null loop
    perform app.referral_earning_close(c.id, 'The booking is credited to another partner now');
  end loop;
  if b.referral_partner_id is not null then
    select * into pr from referral_partners where id = b.referral_partner_id;
    v_reason := case when b.booking_type = 'owner' then 'Owner Booking'
                     when b.management_mode = 'self_managed' then 'Self-Managed rental'
                     when b.renews_booking_id is not null then 'Renewal'
                     when b.status in ('cancelled', 'no_show', 'expired', 'declined') then 'Cancelled booking'
                     when exists (select 1 from disputes d where d.booking_id = b.id and d.status = 'lost') then 'Charged back' end;
    v_base := case when v_reason is null then app.commission_base_cents(b.id) else 0 end;
    if v_reason is null and b.status in ('returned', 'closed') and v_base <= 0 then v_reason := 'Refunded'; end if;
    v_earned := v_reason is null and b.status in ('returned', 'closed') and app.booking_paid_in_full(b.id)
                and not exists (select 1 from disputes d where d.booking_id = b.id and d.status in ('open', 'evidence_submitted'));
    select * into c from referral_partner_earnings where booking_id = b.id and partner_id = b.referral_partner_id and kind = 'earning' for update;
    if c.id is null then
      if v_reason is null then
        v_amount := app.referral_earning_amount(pr.rate_kind, pr.flat_cents, pr.rate_bps, v_base);
        insert into referral_partner_earnings (booking_id, partner_id, kind, rate_kind, flat_cents, rate_bps, base_cents, amount_cents, status, earned_at)
        values (b.id, pr.id, 'earning', pr.rate_kind, pr.flat_cents, pr.rate_bps, v_base, v_amount,
                case when v_earned then 'pending_approval' else 'accruing' end, case when v_earned then now() end);
      end if;
    elsif not c.admin_reversed then
      if v_reason is not null then
        perform app.referral_earning_close(c.id, v_reason);
      else
        v_amount := app.referral_earning_amount(c.rate_kind, c.flat_cents, c.rate_bps, v_base);
        if c.status in ('void', 'reversed') or (c.status = 'paid' and c.reversed_at is not null) then
          -- due again (a cancellation undone): a clawback not paid yet is voided; one already paid is for an Admin to settle
          if c.status = 'paid' then
            update referral_partner_earnings set status = 'void', reason = 'Due again before it was taken back', updated_at = now()
             where clawback_of = c.id and status = 'approved';
            if found then
              update referral_partner_earnings set reversed_at = null, reversed_by = null, reason = null, base_cents = v_base, amount_cents = v_amount, updated_at = now() where id = c.id;
            end if;
          else
            update referral_partner_earnings set status = case when v_earned then 'pending_approval' else 'accruing' end, reversed_at = null, reversed_by = null, reason = null,
                   earned_at = case when v_earned then now() end, base_cents = v_base, amount_cents = v_amount, updated_at = now() where id = c.id;
          end if;
        elsif c.status <> 'paid' then
          update referral_partner_earnings set base_cents = v_base, amount_cents = v_amount,
                 status = case when status = 'accruing' and v_earned then 'pending_approval' when status in ('pending_approval', 'approved') and not v_earned then 'accruing' else status end,
                 earned_at = case when status = 'accruing' and v_earned then now() when status in ('pending_approval', 'approved') and not v_earned then null else earned_at end,
                 approved_at = case when status = 'approved' and (not v_earned or amount_cents <> v_amount) then null else approved_at end,
                 approved_by = case when status = 'approved' and (not v_earned or amount_cents <> v_amount) then null else approved_by end,
                 updated_at = now()
           where id = c.id;
          update referral_partner_earnings set status = 'pending_approval', note = 'The amount changed after it was approved: approve it again' where id = c.id and status = 'approved' and approved_at is null and v_earned;
        end if;
      end if;
    end if;
  end if;
  -- the booking's split follows when what is deducted before Owner Revenue changed
  if v_before is distinct from app.booking_referral_partner_cents(b.id) and exists (select 1 from booking_splits s where s.booking_id = b.id) then
    perform app.compute_booking_split(b.id);
  end if;
end $$;

create or replace function app.referral_partner_sync_trigger() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_booking uuid := case when tg_table_name = 'bookings' then (to_jsonb(new) ->> 'id')::uuid else (to_jsonb(new) ->> 'booking_id')::uuid end;
begin
  if v_booking is not null and (exists (select 1 from bookings x where x.id = v_booking and x.referral_partner_id is not null)
                                or exists (select 1 from referral_partner_earnings e where e.booking_id = v_booking)) then
    perform app.referral_partner_sync(v_booking);
  end if;
  return null;
end $$;
drop trigger if exists bookings_referral_partner_sync_ins on bookings;
create trigger bookings_referral_partner_sync_ins after insert on bookings
  for each row when (new.referral_partner_id is not null) execute function app.referral_partner_sync_trigger();
drop trigger if exists bookings_referral_partner_sync on bookings;
create trigger bookings_referral_partner_sync after update of status, referral_partner_id, rental_charge_cents, discount_cents, staff_discount_cents,
  promo_discount_cents, checked_in_at, return_at, renter_id on bookings
  for each row when (new.referral_partner_id is not null or old.referral_partner_id is not null) execute function app.referral_partner_sync_trigger();
drop trigger if exists payments_referral_partner_sync on payments;
create trigger payments_referral_partner_sync after insert or update of status on payments
  for each row when (new.booking_id is not null) execute function app.referral_partner_sync_trigger();
drop trigger if exists refunds_referral_partner_sync on refunds;
create trigger refunds_referral_partner_sync after insert or update of status on refunds
  for each row execute function app.referral_partner_sync_trigger();
drop trigger if exists disputes_referral_partner_sync on disputes;
create trigger disputes_referral_partner_sync after insert or update of status on disputes
  for each row when (new.booking_id is not null) execute function app.referral_partner_sync_trigger();
drop trigger if exists booking_statements_referral_partner_sync on booking_statements;
create trigger booking_statements_referral_partner_sync after insert or update of sent_at, paid_at on booking_statements
  for each row execute function app.referral_partner_sync_trigger();
drop trigger if exists booking_line_items_referral_partner_sync on booking_line_items;
create trigger booking_line_items_referral_partner_sync after insert or update of payment_id, voided_at on booking_line_items
  for each row execute function app.referral_partner_sync_trigger();

-- ================================================================ 6. Admin: partners
create or replace function app.referral_rate_text(p referral_partners) returns text
language sql immutable as $$
  select case when p.rate_kind = 'flat' then '$' || to_char(p.flat_cents / 100.0, 'FM999,990.00') || ' per completed rental'
              else trim(trailing '.' from trim(trailing '0' from to_char(p.rate_bps / 100.0, 'FM990.00'))) || '% of the rental charge' end
$$;

create or replace function app.referral_partner_row(p referral_partners) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select to_jsonb(p) - 'created_by' - 'decided_by'
    || jsonb_build_object('rate_text', app.referral_rate_text(p),
         'referrals', (select count(*) from bookings b where b.referral_partner_id = p.id),
         'completed', (select count(*) from referral_partner_earnings e where e.partner_id = p.id and e.kind = 'earning' and e.status in ('pending_approval', 'approved', 'paid') and e.reversed_at is null),
         'accruing_cents', (select coalesce(sum(e.amount_cents), 0) from referral_partner_earnings e where e.partner_id = p.id and e.status = 'accruing'),
         'pending_cents', (select coalesce(sum(e.amount_cents), 0) from referral_partner_earnings e where e.partner_id = p.id and e.status = 'pending_approval'),
         'approved_cents', (select coalesce(sum(e.amount_cents), 0) from referral_partner_earnings e where e.partner_id = p.id and e.status = 'approved'),
         'paid_cents', (select coalesce(sum(y.amount_cents), 0) from referral_partner_payouts y where y.partner_id = p.id))
$$;

create or replace function app.referral_partners_read(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
begin
  perform app.assert_admin(p_by);
  return jsonb_build_object('today', app.today(), 'settings', jsonb_build_object('flat_cents', s.referral_partner_flat_cents, 'percent_bps', s.referral_partner_percent_bps),
    'partners', (select coalesce(jsonb_agg(app.referral_partner_row(x) order by (x.status = 'pending') desc, x.created_at desc), '[]'::jsonb) from referral_partners x
                  where nullif(p ->> 'status', '') is null or x.status = p ->> 'status'),
    'waiting', (select count(*) from referral_partners where status = 'pending'));
end $$;

-- A ledger row as the Admin sees it (the renter's first name and the month, the booking number).
create or replace function app.referral_earning_row(e referral_partner_earnings) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('id', e.id, 'kind', e.kind, 'status', e.status, 'partner_id', e.partner_id, 'partner', pr.business_name, 'booking_number', b.booking_number,
           'first_name', split_part(coalesce(r.legal_name, ''), ' ', 1), 'month', to_char(app.local_date(coalesce(b.checked_in_at, b.return_at, b.pickup_at)), 'FMMon YYYY'),
           'booking_status', b.status, 'rate_kind', e.rate_kind, 'flat_cents', e.flat_cents, 'rate_bps', e.rate_bps, 'base_cents', e.base_cents, 'amount_cents', e.amount_cents,
           'reason', e.reason, 'note', e.note, 'earned_at', e.earned_at, 'approved_at', e.approved_at, 'paid_at', e.paid_at, 'payout_id', e.payout_id, 'created_at', e.created_at,
           'approvable', e.status = 'pending_approval',
           'paid_from', case when exists (select 1 from vehicles v where v.id = b.vehicle_id and v.supply_type = 'program_owner') then 'owner_revenue'
                             when exists (select 1 from vehicles v where v.id = b.vehicle_id and v.supply_type = 'partner') then 'carmacars_commission' else 'carmacars' end)
    from bookings b join referral_partners pr on pr.id = e.partner_id left join renters r on r.id = b.renter_id where b.id = e.booking_id
$$;

create or replace function app.referral_partner_detail(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  pr referral_partners;
begin
  perform app.assert_admin(p_by);
  select * into pr from referral_partners where id = (p ->> 'id')::uuid;
  if pr.id is null then raise exception 'Referral partner not found' using errcode = 'P0002'; end if;
  return jsonb_build_object('partner', app.referral_partner_row(pr), 'today', app.today(),
    'earnings', (select coalesce(jsonb_agg(app.referral_earning_row(e) order by e.created_at desc), '[]'::jsonb)
                   from (select * from referral_partner_earnings where partner_id = pr.id order by created_at desc limit 200) e),
    'payouts', (select coalesce(jsonb_agg(to_jsonb(y) - 'recorded_by' order by y.paid_on desc, y.created_at desc), '[]'::jsonb) from referral_partner_payouts y where y.partner_id = pr.id));
end $$;

create or replace function app.referral_earnings_read(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_by);
  return jsonb_build_object('today', app.today(),
    'rows', (select coalesce(jsonb_agg(app.referral_earning_row(e) order by e.created_at desc), '[]'::jsonb)
               from (select * from referral_partner_earnings x
                      where (nullif(p ->> 'status', '') is null or x.status = p ->> 'status')
                        and (nullif(p ->> 'partner', '') is null or x.partner_id = (p ->> 'partner')::uuid)
                      order by x.created_at desc limit 300) e),
    'payouts', (select coalesce(jsonb_agg(jsonb_build_object('id', y.id, 'partner_id', y.partner_id, 'partner', pr.business_name, 'method', y.method, 'reference', y.reference,
                  'paid_on', y.paid_on, 'amount_cents', y.amount_cents, 'note', y.note) order by y.paid_on desc, y.created_at desc), '[]'::jsonb)
                  from (select * from referral_partner_payouts order by paid_on desc, created_at desc limit 200) y join referral_partners pr on pr.id = y.partner_id));
end $$;

-- Add or change a partner. p: {id?, kind, business_name, contact_name, phone, email, address_line1, city, province, postal_code,
-- payout_method, payout_email, rate_kind, flat_cents, rate_bps, referral_code, notes}. A new partner added by an Admin is active.
create or replace function app.referral_partner_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid := nullif(p ->> 'id', '')::uuid;
  o referral_partners;
  s program_settings := app.settings();
  v_code text := upper(nullif(btrim(coalesce(p ->> 'referral_code', '')), ''));
  v_kind text := coalesce(nullif(p ->> 'kind', ''), 'body_shop');
  v_rate_kind text := coalesce(nullif(p ->> 'rate_kind', ''), 'flat');
begin
  perform app.assert_admin(p_by);
  if v_kind not in ('body_shop', 'tow_truck', 'dealership', 'insurance_broker') then raise exception 'Choose body shop, tow truck, dealership or insurance broker' using errcode = '22023'; end if;
  if v_rate_kind not in ('flat', 'percent') then raise exception 'Choose a flat amount or a percentage' using errcode = '22023'; end if;
  if v_code is not null and v_code !~ '^[A-Z0-9]{4,12}$' then raise exception 'A code is 4 to 12 letters and digits' using errcode = '22023'; end if;
  if nullif(btrim(coalesce(p ->> 'business_name', '')), '') is null and v_id is null then raise exception 'Enter the business name' using errcode = '22023'; end if;
  if v_id is null then
    if v_code is not null and not app.referral_code_free(v_code) then raise exception 'That code is already in use' using errcode = '23505'; end if;
    insert into referral_partners (kind, status, business_name, contact_name, phone, email, address_line1, city, province, postal_code, payout_method, payout_email,
                                   rate_kind, flat_cents, rate_bps, referral_code, source, notes, decided_at, decided_by, created_by)
    values (v_kind, 'active', btrim(p ->> 'business_name'), nullif(btrim(coalesce(p ->> 'contact_name', '')), ''), nullif(btrim(coalesce(p ->> 'phone', '')), ''),
            lower(nullif(btrim(coalesce(p ->> 'email', '')), '')), nullif(btrim(coalesce(p ->> 'address_line1', '')), ''), nullif(btrim(coalesce(p ->> 'city', '')), ''),
            coalesce(nullif(btrim(coalesce(p ->> 'province', '')), ''), 'ON'), upper(nullif(btrim(coalesce(p ->> 'postal_code', '')), '')),
            coalesce(nullif(p ->> 'payout_method', ''), 'e_transfer'), lower(nullif(btrim(coalesce(p ->> 'payout_email', '')), '')),
            v_rate_kind, coalesce(nullif(p ->> 'flat_cents', '')::bigint, s.referral_partner_flat_cents), coalesce(nullif(p ->> 'rate_bps', '')::integer, s.referral_partner_percent_bps),
            coalesce(v_code, app.referral_code_new()), 'admin', nullif(btrim(coalesce(p ->> 'notes', '')), ''), now(), p_by, p_by)
    returning * into o;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, 'referral_partner_add', 'referral_partners', o.id::text, jsonb_build_object('kind', o.kind, 'code', o.referral_code, 'rate', app.referral_rate_text(o)));
  else
    select * into o from referral_partners where id = v_id for update;
    if o.id is null then raise exception 'Referral partner not found' using errcode = 'P0002'; end if;
    if v_code is not null and v_code <> o.referral_code and not app.referral_code_free(v_code) then raise exception 'That code is already in use' using errcode = '23505'; end if;
    update referral_partners set
      kind = case when p ? 'kind' then v_kind else kind end,
      business_name = coalesce(nullif(btrim(coalesce(p ->> 'business_name', '')), ''), business_name),
      contact_name = case when p ? 'contact_name' then nullif(btrim(coalesce(p ->> 'contact_name', '')), '') else contact_name end,
      phone = case when p ? 'phone' then nullif(btrim(coalesce(p ->> 'phone', '')), '') else phone end,
      email = case when p ? 'email' then lower(nullif(btrim(coalesce(p ->> 'email', '')), '')) else email end,
      address_line1 = case when p ? 'address_line1' then nullif(btrim(coalesce(p ->> 'address_line1', '')), '') else address_line1 end,
      city = case when p ? 'city' then nullif(btrim(coalesce(p ->> 'city', '')), '') else city end,
      province = case when p ? 'province' then nullif(btrim(coalesce(p ->> 'province', '')), '') else province end,
      postal_code = case when p ? 'postal_code' then upper(nullif(btrim(coalesce(p ->> 'postal_code', '')), '')) else postal_code end,
      payout_method = coalesce(nullif(p ->> 'payout_method', ''), payout_method),
      payout_email = case when p ? 'payout_email' then lower(nullif(btrim(coalesce(p ->> 'payout_email', '')), '')) else payout_email end,
      rate_kind = case when p ? 'rate_kind' then v_rate_kind else rate_kind end,
      flat_cents = coalesce(nullif(p ->> 'flat_cents', '')::bigint, flat_cents),
      rate_bps = coalesce(nullif(p ->> 'rate_bps', '')::integer, rate_bps),
      referral_code = coalesce(v_code, referral_code),
      notes = case when p ? 'notes' then nullif(btrim(coalesce(p ->> 'notes', '')), '') else notes end
     where id = o.id returning * into o;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, 'referral_partner_save', 'referral_partners', o.id::text,
      jsonb_build_object('rate', app.referral_rate_text(o), 'code', o.referral_code, 'note', 'A rate change applies to rentals tied to the partner from now on'));
  end if;
  return app.referral_partner_row(o);
end $$;

-- approve or decline a sign-up; pause, resume or end a partner. p: {id, action}
create or replace function app.referral_partner_decide(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  o referral_partners;
  v_action text := p ->> 'action';
  v_to text;
begin
  perform app.assert_admin(p_by);
  select * into o from referral_partners where id = (p ->> 'id')::uuid for update;
  if o.id is null then raise exception 'Referral partner not found' using errcode = 'P0002'; end if;
  v_to := case v_action when 'approve' then 'active' when 'decline' then 'declined' when 'pause' then 'paused' when 'resume' then 'active' when 'end' then 'ended' end;
  if v_to is null then raise exception 'Unknown action' using errcode = '22023'; end if;
  if v_action = 'approve' and o.status <> 'pending' then raise exception 'Only a sign-up waiting for a decision can be approved' using errcode = '23514'; end if;
  if v_action = 'decline' and o.status <> 'pending' then raise exception 'Only a sign-up waiting for a decision can be declined' using errcode = '23514'; end if;
  if v_action = 'resume' and o.status not in ('paused', 'ended') then raise exception 'Only a paused or ended partner can be resumed' using errcode = '23514'; end if;
  if v_action in ('pause', 'end') and o.status <> 'active' then raise exception 'Only an active partner can be paused or ended' using errcode = '23514'; end if;
  update referral_partners set status = v_to, decided_at = now(), decided_by = p_by where id = o.id returning * into o;
  update tasks set status = 'done', completed_at = now() where dedupe_key = 'referral_partner_signup:' || o.id and status in ('open', 'in_progress', 'waiting') and v_action in ('approve', 'decline');
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, 'referral_partner_' || v_action, 'referral_partners', o.id::text, jsonb_build_object('status', o.status));
  return app.referral_partner_row(o);
end $$;

-- A new link to the partner's own page: the old one stops working.
create or replace function app.referral_partner_link_new(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  o referral_partners;
begin
  perform app.assert_admin(p_by);
  update referral_partners set portal_version = portal_version + 1 where id = (p ->> 'id')::uuid returning * into o;
  if o.id is null then raise exception 'Referral partner not found' using errcode = 'P0002'; end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, 'referral_partner_link_new', 'referral_partners', o.id::text, jsonb_build_object('version', o.portal_version));
  return jsonb_build_object('id', o.id, 'portal_version', o.portal_version);
end $$;

-- Tie a booking to a partner after the fact (the renter forgot the code), or take it off. Not once a kickback is approved or paid.
-- p: {booking: number, partner: id | null, reason}
create or replace function app.referral_partner_credit(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_partner uuid := nullif(p ->> 'partner', '')::uuid;
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
begin
  perform app.assert_admin(p_by);
  select * into b from bookings where booking_number = btrim(coalesce(p ->> 'booking', '')) for update;
  if b.id is null then raise exception 'Booking not found: check the booking number' using errcode = 'P0002'; end if;
  if v_reason is null then raise exception 'Say why' using errcode = '22023'; end if;
  if v_partner is not null and not exists (select 1 from referral_partners where id = v_partner and status in ('active', 'paused')) then raise exception 'Choose an active referral partner' using errcode = '22023'; end if;
  if v_partner is not null and b.referrer_type is not null then raise exception 'This booking already has an owner or field staff referrer: it cannot have a partner too' using errcode = '23514'; end if;
  if exists (select 1 from referral_partner_earnings e where e.booking_id = b.id and e.kind = 'earning' and e.status in ('approved', 'paid') and e.partner_id is distinct from v_partner) then
    raise exception 'The kickback on this booking is approved or paid: reverse it first' using errcode = '23514';
  end if;
  update bookings set referral_partner_id = v_partner where id = b.id;
  perform app.referral_partner_sync(b.id);
  perform app.log_booking_event(b.id, 'adjusted', null, b.status::text, null,
    case when v_partner is null then 'Referral partner removed: ' || v_reason else format('Referral partner set to %s: %s', (select business_name from referral_partners where id = v_partner), v_reason) end, p_by, 'staff');
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, 'referral_partner_credit', 'bookings', b.id::text, jsonb_build_object('partner', v_partner, 'reason', v_reason));
  return jsonb_build_object('booking', b.booking_number, 'partner', v_partner);
end $$;

-- Approve kickbacks pending approval, one by one or all of a partner's. p: {ids: [...]} or {partner}
create or replace function app.referral_earning_approve(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_ids uuid[];
  v_n integer;
begin
  perform app.assert_admin(p_by);
  if jsonb_typeof(p -> 'ids') = 'array' then
    v_ids := array(select (jsonb_array_elements_text(p -> 'ids'))::uuid);
  else
    v_ids := array(select e.id from referral_partner_earnings e where e.partner_id = nullif(p ->> 'partner', '')::uuid and e.status = 'pending_approval');
  end if;
  if coalesce(array_length(v_ids, 1), 0) = 0 then raise exception 'Choose the kickbacks to approve' using errcode = '22023'; end if;
  if exists (select 1 from referral_partner_earnings e where e.id = any (v_ids) and e.status <> 'pending_approval') then
    raise exception 'Only kickbacks pending approval can be approved' using errcode = '23514';
  end if;
  update referral_partner_earnings set status = 'approved', approved_at = now(), approved_by = p_by, note = null, updated_at = now() where id = any (v_ids);
  get diagnostics v_n = row_count;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, 'referral_earning_approve', 'referral_partner_earnings', null, jsonb_build_object('ids', to_jsonb(v_ids)));
  return jsonb_build_object('approved', v_n);
end $$;

-- An Admin reverses a kickback (a mistake, a partner's own rental), with a reason; once paid, the amount is taken off the next payment.
create or replace function app.referral_earning_reverse(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  c referral_partner_earnings;
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
  b uuid;
begin
  perform app.assert_admin(p_by);
  select * into c from referral_partner_earnings where id = (p ->> 'id')::uuid for update;
  if c.id is null or c.kind <> 'earning' then raise exception 'Kickback not found' using errcode = 'P0002'; end if;
  if v_reason is null then raise exception 'Say why the kickback is reversed' using errcode = '22023'; end if;
  if c.status in ('void', 'reversed') or c.reversed_at is not null then raise exception 'This kickback is already reversed' using errcode = '23514'; end if;
  update referral_partner_earnings set admin_reversed = true where id = c.id;
  perform app.referral_earning_close(c.id, v_reason, p_by);
  if exists (select 1 from booking_splits s where s.booking_id = c.booking_id) then perform app.compute_booking_split(c.booking_id); end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, 'referral_earning_reverse', 'referral_partner_earnings', c.id::text, jsonb_build_object('reason', v_reason, 'status_before', c.status));
  return jsonb_build_object('id', c.id, 'reversed', true);
end $$;

-- Record a payment made by hand of a partner's approved kickbacks (with the clawbacks they carry). p: {partner, ids?, method, reference, paid_on, note}
create or replace function app.referral_partner_payout(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_partner uuid := nullif(p ->> 'partner', '')::uuid;
  v_ids uuid[];
  v_total bigint;
  v_method text := coalesce(nullif(p ->> 'method', ''), 'e_transfer');
  v_ref text := nullif(btrim(coalesce(p ->> 'reference', '')), '');
  v_on date := coalesce(nullif(p ->> 'paid_on', '')::date, app.today());
  v_id uuid;
begin
  perform app.assert_admin(p_by);
  if v_partner is null or not exists (select 1 from referral_partners where id = v_partner) then raise exception 'Choose the referral partner' using errcode = '22023'; end if;
  if jsonb_typeof(p -> 'ids') = 'array' then
    v_ids := array(select (jsonb_array_elements_text(p -> 'ids'))::uuid);
  else
    v_ids := array(select e.id from referral_partner_earnings e where e.partner_id = v_partner and e.status = 'approved');
  end if;
  if coalesce(array_length(v_ids, 1), 0) = 0 then raise exception 'Nothing approved to pay' using errcode = '22023'; end if;
  if exists (select 1 from referral_partner_earnings e where e.id = any (v_ids) and (e.partner_id <> v_partner or e.status <> 'approved')) then
    raise exception 'Only approved kickbacks of this partner can be paid' using errcode = '23514';
  end if;
  if v_method not in ('e_transfer', 'cheque', 'bank_transfer', 'cash', 'other') then raise exception 'Choose how it was paid: e-Transfer, cheque, bank transfer, cash or another way' using errcode = '22023'; end if;
  if v_method in ('e_transfer', 'bank_transfer', 'cheque') and (v_ref is null or length(v_ref) < 3) then raise exception 'Enter the reference of the payment (e-Transfer or transfer number, cheque number)' using errcode = '22023'; end if;
  if v_method = 'other' and nullif(btrim(coalesce(p ->> 'note', '')), '') is null then raise exception 'Say how it was paid' using errcode = '22023'; end if;
  if v_on > app.today() then raise exception 'The date paid cannot be in the future' using errcode = '22023'; end if;
  select sum(amount_cents) into v_total from referral_partner_earnings where id = any (v_ids);
  if v_total <= 0 then raise exception 'These add up to % after clawbacks: nothing to pay until more kickbacks are approved', app.fmt_money(v_total) using errcode = '23514'; end if;
  insert into referral_partner_payouts (partner_id, method, reference, paid_on, amount_cents, note, recorded_by)
  values (v_partner, v_method, v_ref, v_on, v_total, nullif(btrim(coalesce(p ->> 'note', '')), ''), p_by) returning id into v_id;
  update referral_partner_earnings set status = 'paid', payout_id = v_id, paid_at = now(), updated_at = now() where id = any (v_ids);
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'referral_partner_payout', 'referral_partner_payouts', v_id::text, jsonb_build_object('partner', v_partner, 'ids', to_jsonb(v_ids), 'amount_cents', v_total, 'method', v_method, 'reference', v_ref));
  return jsonb_build_object('payout_id', v_id, 'amount_cents', v_total, 'count', array_length(v_ids, 1));
end $$;

-- ================================================================ 7. the public sign-up and the partner's own page
-- A business signs up on /partners/body-shops or /partners/tow-trucks: a pending partner and a task for the Admins. Nothing is
-- active or paid until an Admin approves it. The same address twice is one sign-up (answered the same, so the form tells nothing).
create or replace function public.server_referral_partner_signup(p jsonb, p_ip text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_set program_settings := app.settings();
  v_kind text := coalesce(nullif(p ->> 'kind', ''), 'body_shop');
  v_email text := lower(nullif(btrim(coalesce(p ->> 'email', '')), ''));
  v_name text := nullif(btrim(coalesce(p ->> 'business_name', '')), '');
  v_id uuid;
begin
  if nullif(btrim(p_ip), '') is not null and not app.rate_limit('rps:ip:' || btrim(p_ip), v_set.lead_hourly_limit, interval '1 hour') then
    return jsonb_build_object('ok', false, 'error', 'rate_limited');
  end if;
  if v_kind not in ('body_shop', 'tow_truck', 'dealership', 'insurance_broker') then raise exception 'Choose the kind of business' using errcode = '22023'; end if;
  if v_name is null or length(v_name) < 2 then raise exception 'Enter the business name' using errcode = '22023'; end if;
  if nullif(btrim(coalesce(p ->> 'contact_name', '')), '') is null then raise exception 'Enter the name of the person we talk to' using errcode = '22023'; end if;
  if v_email is null or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter a full email address, for example name@example.com' using errcode = '22023'; end if;
  if nullif(btrim(coalesce(p ->> 'phone', '')), '') is null then raise exception 'Enter a phone number' using errcode = '22023'; end if;
  if exists (select 1 from referral_partners where email = v_email and status in ('pending', 'active', 'paused')) then
    return jsonb_build_object('ok', true);
  end if;
  insert into referral_partners (kind, status, business_name, contact_name, phone, email, address_line1, city, province, postal_code, payout_email, rate_kind, flat_cents, rate_bps,
                                 referral_code, source, signup_note)
  values (v_kind, 'pending', left(v_name, 120), left(btrim(p ->> 'contact_name'), 120), left(btrim(p ->> 'phone'), 40), v_email,
          left(nullif(btrim(coalesce(p ->> 'address_line1', '')), ''), 200), left(nullif(btrim(coalesce(p ->> 'city', '')), ''), 80),
          coalesce(left(nullif(btrim(coalesce(p ->> 'province', '')), ''), 40), 'ON'), left(upper(nullif(btrim(coalesce(p ->> 'postal_code', '')), '')), 12), v_email,
          'flat', v_set.referral_partner_flat_cents, v_set.referral_partner_percent_bps, app.referral_code_new(), 'signup', left(nullif(btrim(coalesce(p ->> 'note', '')), ''), 1000))
  returning id into v_id;
  perform app.raise_task(p_type => 'referral_partner_signup', p_title => format('Referral partner sign-up: %s', v_name),
    p_detail => format('%s (%s) asked to join the referral program. Open Referral partners to approve or decline. Nothing is active until you approve it.', v_name, replace(v_kind, '_', ' ')),
    p_related_table => 'referral_partners', p_related_id => v_id, p_dedupe => 'referral_partner_signup:' || v_id, p_queue => 'admin');
  return jsonb_build_object('ok', true);
end $$;

-- The partner's own page: only what they need, never a renter's details beyond the first name and the month.
create or replace function public.server_referral_partner_portal(p_partner uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  pr referral_partners;
begin
  select * into pr from referral_partners where id = p_partner and status in ('active', 'paused', 'ended');
  if pr.id is null then return null; end if;
  return jsonb_build_object('partner', jsonb_build_object('business_name', pr.business_name, 'kind', pr.kind, 'status', pr.status, 'referral_code', pr.referral_code,
           'rate_text', app.referral_rate_text(pr), 'portal_version', pr.portal_version),
    'totals', jsonb_build_object(
      'referrals', (select count(*) from bookings b where b.referral_partner_id = pr.id and b.status not in ('cancelled', 'no_show', 'expired', 'declined', 'requested', 'offered')),
      'accruing_cents', (select coalesce(sum(e.amount_cents), 0) from referral_partner_earnings e where e.partner_id = pr.id and e.status = 'accruing'),
      'pending_cents', (select coalesce(sum(e.amount_cents), 0) from referral_partner_earnings e where e.partner_id = pr.id and e.status in ('pending_approval', 'approved')),
      'paid_cents', (select coalesce(sum(y.amount_cents), 0) from referral_partner_payouts y where y.partner_id = pr.id)),
    'rows', (select coalesce(jsonb_agg(x order by x ->> 'sort' desc), '[]'::jsonb) from (
               select jsonb_build_object('first_name', split_part(coalesce(r.legal_name, ''), ' ', 1),
                        'month', to_char(app.local_date(coalesce(b.checked_in_at, b.return_at, b.pickup_at)), 'FMMon YYYY'),
                        'sort', to_char(coalesce(b.checked_in_at, b.return_at, b.pickup_at), 'YYYYMMDDHH24MISS'),
                        'status', case e.status when 'accruing' then 'Rental not finished yet' when 'pending_approval' then 'Being approved' when 'approved' then 'Approved, to be paid'
                                                when 'paid' then 'Paid' when 'reversed' then 'Not payable' else 'Not payable' end,
                        'amount_cents', e.amount_cents, 'paid_on', (select y.paid_on from referral_partner_payouts y where y.id = e.payout_id)) as x
                 from referral_partner_earnings e join bookings b on b.id = e.booking_id left join renters r on r.id = b.renter_id
                where e.partner_id = pr.id and e.kind = 'earning' order by coalesce(b.checked_in_at, b.return_at, b.pickup_at) desc limit 100) q));
end $$;

-- What the public landing pages say about the rate.
create or replace function public.referral_program_public() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('flat_cents', s.referral_partner_flat_cents, 'percent_bps', s.referral_partner_percent_bps) from (select (app.settings()).*) s
$$;

-- ================================================================ 8. Add a rental: Referred by
-- p.referral_code: a referral partner's code, typed by staff. An unknown or inactive code is refused (so a typing mistake shows).
alter function app.manual_rental_create(uuid, jsonb) rename to manual_rental_create_pre0164;
create or replace function app.manual_rental_create(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_code text := upper(nullif(btrim(coalesce(p ->> 'referral_code', '')), ''));
  v_partner uuid;
  v_out jsonb;
begin
  if v_code is not null then
    v_partner := app.referral_partner_by_code(v_code);
    if v_partner is null then raise exception 'No active referral partner has the code %. Check it, or leave Referred by empty', v_code using errcode = '22023'; end if;
  end if;
  v_out := app.manual_rental_create_pre0164(p_by, p - 'referral_code');
  if v_partner is not null and (v_out ->> 'booking_id') ~ '^[0-9a-f-]{36}$' then
    update bookings set referral_partner_id = v_partner where id = (v_out ->> 'booking_id')::uuid and referrer_type is null;
  end if;
  return v_out;
end $$;

-- ================================================================ 9. RentalCoverage: the public face, the click, the Admin report
-- Whether the site shows the link, and its name: nothing else (the link itself is read by the server for the redirect).
create or replace function app.coverage_affiliate_usable(a coverage_affiliate) returns boolean
language sql immutable as $$
  select a.enabled and a.link_url is not null and (position('{id}' in a.link_url) = 0 or nullif(btrim(coalesce(a.affiliate_id, '')), '') is not null)
$$;
create or replace function public.coverage_affiliate_public() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('enabled', app.coverage_affiliate_usable(a), 'name', a.display_name) from coverage_affiliate a
$$;

-- A click from the site (through /go/coverage): recorded when the link is on, and the link returned for the redirect.
-- p: {placement, visitor_id?, booking_number?}
create or replace function public.server_coverage_click(p jsonb, p_ip text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  a coverage_affiliate;
  v_place text := coalesce(nullif(p ->> 'placement', ''), 'other');
  v_visitor uuid := case when coalesce(p ->> 'visitor_id', '') ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then (p ->> 'visitor_id')::uuid end;
  v_booking uuid;
begin
  select * into a from coverage_affiliate;
  if not app.coverage_affiliate_usable(a) then return jsonb_build_object('ok', false); end if;
  if v_place not in ('requirements', 'card_guide', 'booking_step', 'booking_page', 'other') then v_place := 'other'; end if;
  if nullif(btrim(p_ip), '') is null or app.rate_limit('cov:ip:' || btrim(p_ip), 60, interval '1 hour') then
    select id into v_booking from bookings where booking_number = nullif(btrim(coalesce(p ->> 'booking_number', '')), '');
    insert into coverage_clicks (placement, visitor_id, booking_id) values (v_place, v_visitor, v_booking);
  end if;
  return jsonb_build_object('ok', true, 'link_url', a.link_url, 'affiliate_id', a.affiliate_id, 'name', a.display_name);
end $$;

create or replace function app.coverage_affiliate_read(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  a coverage_affiliate;
begin
  perform app.assert_admin(p_by);
  select * into a from coverage_affiliate;
  return jsonb_build_object('today', app.today(),
    'settings', jsonb_build_object('display_name', a.display_name, 'link_url', a.link_url, 'affiliate_id', a.affiliate_id, 'enabled', a.enabled, 'usable', app.coverage_affiliate_usable(a), 'updated_at', a.updated_at),
    'totals', jsonb_build_object('clicks', (select count(*) from coverage_clicks), 'clicks_30d', (select count(*) from coverage_clicks where clicked_at > now() - interval '30 days'),
      'visitors', (select count(distinct visitor_id) from coverage_clicks), 'with_booking', (select count(*) from coverage_clicks where booking_id is not null),
      'received_cents', (select coalesce(sum(amount_cents), 0) from coverage_affiliate_payments)),
    'by_place', (select coalesce(jsonb_agg(jsonb_build_object('placement', x.placement, 'clicks', x.n, 'visitors', x.v, 'with_booking', x.b) order by x.n desc), '[]'::jsonb)
                   from (select placement, count(*) n, count(distinct visitor_id) v, count(booking_id) b from coverage_clicks group by placement) x),
    'by_month', (select coalesce(jsonb_agg(jsonb_build_object('month', to_char(m, 'FMMon YYYY'), 'clicks', n, 'visitors', v) order by m desc), '[]'::jsonb)
                   from (select date_trunc('month', clicked_at at time zone 'America/Toronto') m, count(*) n, count(distinct visitor_id) v from coverage_clicks
                          where clicked_at > now() - interval '13 months' group by 1) x),
    'recent', (select coalesce(jsonb_agg(jsonb_build_object('at', c.clicked_at, 'placement', c.placement, 'booking_number', b.booking_number) order by c.clicked_at desc), '[]'::jsonb)
                 from (select * from coverage_clicks order by clicked_at desc limit 50) c left join bookings b on b.id = c.booking_id),
    'payments', (select coalesce(jsonb_agg(jsonb_build_object('id', y.id, 'received_on', y.received_on, 'amount_cents', y.amount_cents, 'period_note', y.period_note, 'reference', y.reference, 'note', y.note)
                   order by y.received_on desc, y.created_at desc), '[]'::jsonb) from coverage_affiliate_payments y));
end $$;

-- p: {link_url, affiliate_id, display_name, enabled}. A link pasted for the first time turns the program on unless enabled is false.
create or replace function app.coverage_affiliate_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  a coverage_affiliate;
  o coverage_affiliate;
  v_url text := case when p ? 'link_url' then nullif(btrim(coalesce(p ->> 'link_url', '')), '') end;
  v_id text := case when p ? 'affiliate_id' then nullif(btrim(coalesce(p ->> 'affiliate_id', '')), '') end;
  v_enabled boolean;
begin
  perform app.assert_admin(p_by);
  select * into o from coverage_affiliate;
  if p ? 'link_url' and v_url is not null and v_url !~ '^https://[^[:space:]]+$' then raise exception 'Paste the affiliate link exactly as the affiliate dashboard gives it: it starts with https://' using errcode = '22023'; end if;
  v_enabled := coalesce((p ->> 'enabled')::boolean, case when p ? 'link_url' and v_url is not null and o.link_url is null then true else o.enabled end);
  if v_enabled and not (case when p ? 'link_url' then v_url else o.link_url end) is not null then raise exception 'Paste the affiliate link before turning the program on' using errcode = '22023'; end if;
  update coverage_affiliate set
    link_url = case when p ? 'link_url' then v_url else link_url end,
    affiliate_id = case when p ? 'affiliate_id' then v_id else affiliate_id end,
    display_name = coalesce(nullif(btrim(coalesce(p ->> 'display_name', '')), ''), display_name),
    enabled = v_enabled, updated_by = p_by, updated_at = now()
   returning * into a;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'coverage_affiliate_save', 'coverage_affiliate', 'singleton', jsonb_build_object('enabled', o.enabled, 'has_link', o.link_url is not null),
          jsonb_build_object('enabled', a.enabled, 'has_link', a.link_url is not null));
  return jsonb_build_object('enabled', a.enabled, 'usable', app.coverage_affiliate_usable(a));
end $$;

-- What RentalCoverage paid us, entered by hand. p: {received_on, amount_cents, period_note, reference, note}
create or replace function app.coverage_affiliate_payment_add(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_on date := coalesce(nullif(p ->> 'received_on', '')::date, app.today());
  v_cents bigint := nullif(p ->> 'amount_cents', '')::bigint;
  v_id uuid;
begin
  perform app.assert_admin(p_by);
  if v_cents is null or v_cents <= 0 then raise exception 'Enter the amount received' using errcode = '22023'; end if;
  if v_on > app.today() then raise exception 'The date received cannot be in the future' using errcode = '22023'; end if;
  insert into coverage_affiliate_payments (received_on, amount_cents, period_note, reference, note, recorded_by)
  values (v_on, v_cents, nullif(btrim(coalesce(p ->> 'period_note', '')), ''), nullif(btrim(coalesce(p ->> 'reference', '')), ''), nullif(btrim(coalesce(p ->> 'note', '')), ''), p_by)
  returning id into v_id;
  return jsonb_build_object('id', v_id);
end $$;

-- ================================================================ 10. the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0164;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'admin_read' and p_name in ('referral_partners', 'referral_partner', 'referral_earnings', 'coverage_affiliate') then
    perform app.door_begin(p_user, p_aal);
    return case p_name
      when 'referral_partners' then app.referral_partners_read(p_user, coalesce(p, '{}'::jsonb))
      when 'referral_partner' then app.referral_partner_detail(p_user, coalesce(p, '{}'::jsonb))
      when 'referral_earnings' then app.referral_earnings_read(p_user, coalesce(p, '{}'::jsonb))
      else app.coverage_affiliate_read(p_user, coalesce(p, '{}'::jsonb)) end;
  end if;
  if p_call = 'admin_do' and p_name in ('referral_partner_save', 'referral_partner_decide', 'referral_partner_link_new', 'referral_partner_credit', 'referral_earning_approve',
                                        'referral_earning_reverse', 'referral_partner_payout', 'coverage_affiliate_save', 'coverage_affiliate_payment_add') then
    perform app.door_begin(p_user, p_aal);
    return case p_name
      when 'referral_partner_save' then app.referral_partner_save(p_user, coalesce(p, '{}'::jsonb))
      when 'referral_partner_decide' then app.referral_partner_decide(p_user, coalesce(p, '{}'::jsonb))
      when 'referral_partner_link_new' then app.referral_partner_link_new(p_user, coalesce(p, '{}'::jsonb))
      when 'referral_partner_credit' then app.referral_partner_credit(p_user, coalesce(p, '{}'::jsonb))
      when 'referral_earning_approve' then app.referral_earning_approve(p_user, coalesce(p, '{}'::jsonb))
      when 'referral_earning_reverse' then app.referral_earning_reverse(p_user, coalesce(p, '{}'::jsonb))
      when 'referral_partner_payout' then app.referral_partner_payout(p_user, coalesce(p, '{}'::jsonb))
      when 'coverage_affiliate_save' then app.coverage_affiliate_save(p_user, coalesce(p, '{}'::jsonb))
      else app.coverage_affiliate_payment_add(p_user, coalesce(p, '{}'::jsonb)) end;
  end if;
  return app.door_pre0164(p_user, p_aal, p_call, p_name, p);
end $$;

-- To do: a sign-up waiting for a decision is a task (raised above, closed when decided); a kickback waiting for approval is listed
-- on Referral partners.

-- ================================================================ privileges
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['door', 'door_pre0164', 'manual_rental_create', 'manual_rental_create_pre0164', 'resolve_referrer',
              'referral_code_free', 'referral_code_new', 'referral_partner_by_code', 'referral_earning_amount', 'booking_referral_partner_cents', 'booking_staff_commission_cents',
              'referral_earning_close', 'referral_partner_sync', 'referral_partner_sync_trigger', 'referral_rate_text', 'referral_partner_row', 'referral_partners_read',
              'referral_earning_row', 'referral_partner_detail', 'referral_earnings_read', 'referral_partner_save', 'referral_partner_decide', 'referral_partner_link_new',
              'referral_partner_credit', 'referral_earning_approve', 'referral_earning_reverse', 'referral_partner_payout', 'coverage_affiliate_usable',
              'coverage_affiliate_read', 'coverage_affiliate_save', 'coverage_affiliate_payment_add']))
        or (n.nspname = 'public' and p.proname = any (array['server_referral_partner_signup', 'server_referral_partner_portal', 'server_coverage_click']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
-- the public reads (anon): whether a code is a partner's, whether the coverage link is on, the program's rate
revoke all on function public.referral_partner_code_ok(text), public.coverage_affiliate_public(), public.referral_program_public() from public;
grant execute on function public.referral_partner_code_ok(text), public.coverage_affiliate_public(), public.referral_program_public() to anon, authenticated, service_role;
-- triggers run as the table's owner; the functions they call are not for browser sessions
revoke all on function app.resolve_referrer() from public, anon, authenticated;
grant execute on function app.resolve_referrer() to service_role;

-- row audit for the new tables (not app.attach_audit(): it would add the tables earlier migrations left without one)
do $$
declare t text;
begin
  foreach t in array array['referral_partners', 'referral_partner_payouts', 'referral_partner_earnings', 'coverage_affiliate', 'coverage_affiliate_payments'] loop
    execute format('create trigger %I after insert or update or delete on %I for each row execute function app.audit_row()', 'audit_' || t, t);
  end loop;
end $$;

-- GUIDES 0164 START (generated by supabase/seed/0164_gen_guides.mjs from docs/guides/content; do not edit by hand)
select app.guide_release_section('renter', 'find-a-car-and-send-a-request', 'chapter', 'start-here', 'Every booking starts as a request. A person checks the car and the price, then sends you an offer. Nothing is charged until you approve, sign and pay.

:::flow
Request | You pick a car and dates
Offer | We confirm the price
Sign | The rental agreement
Pay | Your card is authorized
Verify | Licence, selfie, coverage
Pick up | We hand over the keys
:::

## Find a car

Start on carmacars.ca. You do not need to sign in to look around.

1. Go to `carmacars.ca` and press **Find a car**.
2. Add your pickup and return dates. The list then shows the cars that are free and what the whole trip costs.
3. Narrow the list with Filters: type, seats, transmission and daily rate.
4. Open a car to see its photos, rates, what is included and its own calendar. Its car code (like CC-7F3A) is under the price: quote it when you call or chat with us, and we know the car at once.

![](/guides/img/public-02-cars-desktop-b6cd4fb8.jpg "desktop; size: 1440 880; address: carmacars.ca/cars; pins: 1 86.1 4.0, 2 11.1 56.8, 3 3.0 82.3, 4 34.0 87.5")

## Choose your dates on the car page

1. Under Dates and price, tap your pickup date, then your return date. Hatched days are already booked.
2. Choose the Pickup time and the Return time.
3. Want it brought to you? Tick **Deliver it to me** or **Pick it up from me at the end**. Open Add-ons to add a baby seat, flowers, a full tank and more.
4. Check Your estimate, then press **Request to book**. The add-ons you chose come with you.

![](/guides/img/public-03-car-page-desktop-73be4d63.jpg "desktop; size: 1120 760; address: carmacars.ca/cars/bmw-330i; pins: 1 24.4 39.7, 2 12.9 68.2, 3 3.0 76.2, 4 97.0 50.0")

> Watch out: A request does not hold the car. The car is booked only once you approve the offer, sign and pay.

## Send your request

The request has five short steps. Your answers are saved as you go, so you can come back.

1. Step 1, Dates and delivery: check the car and tap your dates in the calendar.
2. Set the Pickup time and Return time. Any time, day or night, with at least 2 hours of notice.
3. Your request, on the right, shows the estimated total as you go.

![](/guides/img/public-04-book-1-trip-desktop-63a3738b.jpg "desktop; size: 1440 1002; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 1 9.2 67.1, 2 15.3 91.0, 3 91.1 54.7")

4. Choose where you get the car: **At our location**, **Deliver it to an address** or **At the airport**. Then choose where you return it.
5. Press **Continue to driver details**.

![](/guides/img/public-04-book-1-trip-desktop-befba4f6.jpg "desktop; size: 760 942; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 4 5.3 26.2, 5 61.8 93.3")

6. Step 2, The driver: fill in your first and last name, email, mobile number and date of birth.
7. Someone else will drive too? Add them under Additional drivers. Each needs a G2 or G licence and signs the agreement.
8. Press **Continue to licence**.

![](/guides/img/public-05-book-2-driver-desktop-7b572499.jpg "desktop; size: 980 1032; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 6 30.6 21.1, 7 30.6 64.8, 8 55.6 88.0")

9. Step 3: choose your Licence class, for example Ontario G2.
10. Choose how the car is covered: Option 1 (OPCF 27 on your own auto policy), Option 2 (rental coverage on your credit card) or Option 3 (the CarmaCars Protection Plan). You can change this any time before pickup.
11. Choose the Booking type: Standard, or Non-refundable for 10% off with no refund.
12. Add anything we should know in the notes, for example a flight number.
13. Press **Continue to add-ons**. Step 4, Add-ons: tick what you want (see Add-ons below), then press **Review request**.

![](/guides/img/public-06-book-3-licence-desktop-22bb144e.jpg "desktop; size: 760 1452; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 9 61.8 11.2, 10 92.1 32.2, 11 92.1 50.4, 12 92.1 66.9, 13 71.7 97.0")

14. Step 5, Check it and send: read every line. Use Edit beside a line to change it.
15. Tick the box to confirm you are 18 or older and agree to the Terms of use and Privacy policy.
16. Press **Send request**. Nothing is charged and no card is needed.

![](/guides/img/public-07-book-4-review-desktop-005f4c0b.jpg "desktop; size: 760 492; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 14 92.1 24.8, 15 3.9 59.3, 16 73.7 89.0")

17. The confirmation shows your request number, for example CC-10021. Keep it for any question.
18. A person checks the calendar, your dates and your place, usually within 2 hours, day or night. Your offer arrives by email and in Trips.

![](/guides/img/public-08-book-5-sent-phone-14a99ccf.jpg "phone; size: 390 755; pins: 17 32.8 12.3")

## Upload your licence

Right after you send your request: the front and back of your licence and a selfie holding it.

1. On the Request sent page, press **Upload your licence** (or open your booking and press **Your licence**).
2. Take each photo with your phone, or choose it. Add the licence number and expiry date if we ask: it must be valid after your return.
3. Rented with us before? A licence on file that is still valid is used again; nothing to upload.

> Tip: You need your licence on file to accept the offer.

## Add-ons

Extras for your trip, such as a baby seat, a child or booster seat, flowers waiting in the car, a chauffeur, an umbrella, a phone charger or a full tank of gas.

1. On the car page (under Add-ons) or in step 4 of the request, tick an add-on or use + and − for seats. The estimate shows the price at once.
2. Each add-on shows its price: a trip, a day (with the most for a trip) or an hour. HST is added.
3. Some need notice, for example flowers need 24 hours. Seats and other items show how many are left for your dates.
4. A chauffeur is confirmed by our team in your offer.

With a full tank of gas (prepaid) you can return the car at any fuel level, with no fuel charge.

## A discount code

A code from a game on the site, an offer we sent you, or from our team.

- On the last step of your request, type it in the promo code box. The price shows the discount at once.
- Every code has a last day. You find it in the email or text that brought the code, and under Your discount codes on Your trips.
- If you have not used a code, we remind you 3 days before its last day and the day before, by email and text as you chose in Profile. A code you won in a game is always reminded; a reminder of an offer comes only if you agreed to get offers, and every email has an Unsubscribe link.
- A code that ended is refused with "This code has expired". You can still send the request without it.

## Ask in the chat

The chat button sits in the corner of every page.

1. Press it and write your question: a car, your dates, the price, how booking works. The CarmaCars assistant answers right away with prices from our booking system.
2. Want a person? Press **Talk to a person**. When our team is away, leave your name and email or phone with **Send my details** and tick "Email me a copy of this chat".
3. Press **End chat** when you are done. If you gave your email, a copy of the chat arrives by email.

A price in the chat is for the dates you asked. Nothing is booked until you approve an offer, sign and pay.

## Carry on later

- Your name, email and mobile number are saved as you type them, so nothing is lost if you stop. We open an account for you with that email.
- Every form that saves as you type says so under it: "Saved as you type so you can pick up where you left off.", with a link to the privacy policy.
- On the same phone or computer, open `carmacars.ca/account` (or the request page again) to carry on, no password needed.
- We send you one email, "Continue your request". One tap signs you in, confirms your email and opens your request on any device. You need it before you can accept an offer, sign or pay.
- Already have an account? The form says "You have an account: we sent you a sign-in link".
', 'Find a car and send a request', 'Search the fleet, pick dates and add-ons, and send a request in five short steps.',
  'Every booking starts as a request. A person checks the car and the price, then sends you an offer. Nothing is charged until you approve, sign and pay.

:::flow
Request | You pick a car and dates
Offer | We confirm the price
Sign | The rental agreement
Pay | Your card is authorized
Verify | Licence, selfie, coverage
Pick up | We hand over the keys
:::

## Find a car

Start on carmacars.ca. You do not need to sign in to look around.

1. Go to `carmacars.ca` and press **Find a car**.
2. Add your pickup and return dates. The list then shows the cars that are free and what the whole trip costs.
3. Narrow the list with Filters: type, seats, transmission and daily rate.
4. Open a car to see its photos, rates, what is included and its own calendar. Its car code (like CC-7F3A) is under the price: quote it when you call or chat with us, and we know the car at once.

![](/guides/img/public-02-cars-desktop-b6cd4fb8.jpg "desktop; size: 1440 880; address: carmacars.ca/cars; pins: 1 86.1 4.0, 2 11.1 56.8, 3 3.0 82.3, 4 34.0 87.5")

## Choose your dates on the car page

1. Under Dates and price, tap your pickup date, then your return date. Hatched days are already booked.
2. Choose the Pickup time and the Return time.
3. Want it brought to you? Tick **Deliver it to me** or **Pick it up from me at the end**. Open Add-ons to add a baby seat, flowers, a full tank and more.
4. Check Your estimate, then press **Request to book**. The add-ons you chose come with you.

![](/guides/img/public-03-car-page-desktop-73be4d63.jpg "desktop; size: 1120 760; address: carmacars.ca/cars/bmw-330i; pins: 1 24.4 39.7, 2 12.9 68.2, 3 3.0 76.2, 4 97.0 50.0")

> Watch out: A request does not hold the car. The car is booked only once you approve the offer, sign and pay.

## Send your request

The request has five short steps. Your answers are saved as you go, so you can come back.

1. Step 1, Dates and delivery: check the car and tap your dates in the calendar.
2. Set the Pickup time and Return time. Any time, day or night, with at least 2 hours of notice.
3. Your request, on the right, shows the estimated total as you go.

![](/guides/img/public-04-book-1-trip-desktop-63a3738b.jpg "desktop; size: 1440 1002; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 1 9.2 67.1, 2 15.3 91.0, 3 91.1 54.7")

4. Choose where you get the car: **At our location**, **Deliver it to an address** or **At the airport**. Then choose where you return it.
5. Press **Continue to driver details**.

![](/guides/img/public-04-book-1-trip-desktop-befba4f6.jpg "desktop; size: 760 942; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 4 5.3 26.2, 5 61.8 93.3")

6. Step 2, The driver: fill in your first and last name, email, mobile number and date of birth.
7. Someone else will drive too? Add them under Additional drivers. Each needs a G2 or G licence and signs the agreement.
8. Press **Continue to licence**.

![](/guides/img/public-05-book-2-driver-desktop-7b572499.jpg "desktop; size: 980 1032; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 6 30.6 21.1, 7 30.6 64.8, 8 55.6 88.0")

9. Step 3: choose your Licence class, for example Ontario G2.
10. Choose how the car is covered: Option 1 (OPCF 27 on your own auto policy), Option 2 (rental coverage on your credit card) or Option 3 (the CarmaCars Protection Plan). You can change this any time before pickup. You may also see a link to RentalCoverage, a separate company''s optional product. It is not issued or handled by CarmaCars and does not replace the option you choose here, and we may earn a commission if you buy it, at no extra cost to you.
11. Choose the Booking type: Standard, or Non-refundable for 10% off with no refund.
12. Add anything we should know in the notes, for example a flight number. If a body shop, a tow company or a friend sent you, type their name or the referral code from their card in Did someone refer you?.
13. Press **Continue to add-ons**. Step 4, Add-ons: tick what you want (see Add-ons below), then press **Review request**.

![](/guides/img/public-06-book-3-licence-desktop-22bb144e.jpg "desktop; size: 760 1452; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 9 61.8 11.2, 10 92.1 32.2, 11 92.1 50.4, 12 92.1 66.9, 13 71.7 97.0")

14. Step 5, Check it and send: read every line. Use Edit beside a line to change it.
15. Tick the box to confirm you are 18 or older and agree to the Terms of use and Privacy policy.
16. Press **Send request**. Nothing is charged and no card is needed.

![](/guides/img/public-07-book-4-review-desktop-005f4c0b.jpg "desktop; size: 760 492; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 14 92.1 24.8, 15 3.9 59.3, 16 73.7 89.0")

17. The confirmation shows your request number, for example CC-10021. Keep it for any question.
18. A person checks the calendar, your dates and your place, usually within 2 hours, day or night. Your offer arrives by email and in Trips.

![](/guides/img/public-08-book-5-sent-phone-14a99ccf.jpg "phone; size: 390 755; pins: 17 32.8 12.3")

## Upload your licence

Right after you send your request: the front and back of your licence and a selfie holding it.

1. On the Request sent page, press **Upload your licence** (or open your booking and press **Your licence**).
2. Take each photo with your phone, or choose it. Add the licence number and expiry date if we ask: it must be valid after your return.
3. Rented with us before? A licence on file that is still valid is used again; nothing to upload.

> Tip: You need your licence on file to accept the offer.

## Add-ons

Extras for your trip, such as a baby seat, a child or booster seat, flowers waiting in the car, a chauffeur, an umbrella, a phone charger or a full tank of gas.

1. On the car page (under Add-ons) or in step 4 of the request, tick an add-on or use + and − for seats. The estimate shows the price at once.
2. Each add-on shows its price: a trip, a day (with the most for a trip) or an hour. HST is added.
3. Some need notice, for example flowers need 24 hours. Seats and other items show how many are left for your dates.
4. A chauffeur is confirmed by our team in your offer.

With a full tank of gas (prepaid) you can return the car at any fuel level, with no fuel charge.

## A discount code

A code from a game on the site, an offer we sent you, or from our team.

- On the last step of your request, type it in the promo code box. The price shows the discount at once.
- Every code has a last day. You find it in the email or text that brought the code, and under Your discount codes on Your trips.
- If you have not used a code, we remind you 3 days before its last day and the day before, by email and text as you chose in Profile. A code you won in a game is always reminded; a reminder of an offer comes only if you agreed to get offers, and every email has an Unsubscribe link.
- A code that ended is refused with "This code has expired". You can still send the request without it.

## Ask in the chat

The chat button sits in the corner of every page.

1. Press it and write your question: a car, your dates, the price, how booking works. The CarmaCars assistant answers right away with prices from our booking system.
2. Want a person? Press **Talk to a person**. When our team is away, leave your name and email or phone with **Send my details** and tick "Email me a copy of this chat".
3. Press **End chat** when you are done. If you gave your email, a copy of the chat arrives by email.

A price in the chat is for the dates you asked. Nothing is booked until you approve an offer, sign and pay.

## Carry on later

- Your name, email and mobile number are saved as you type them, so nothing is lost if you stop. We open an account for you with that email.
- Every form that saves as you type says so under it: "Saved as you type so you can pick up where you left off.", with a link to the privacy policy.
- On the same phone or computer, open `carmacars.ca/account` (or the request page again) to carry on, no password needed.
- We send you one email, "Continue your request". One tap signs you in, confirms your email and opens your request on any device. You need it before you can accept an offer, sign or pay.
- Already have an account? The form says "You have an account: we sent you a sign-in link".
',
  '<p class="gd-p">Every booking starts as a request. A person checks the car and the price, then sends you an offer. Nothing is charged until you approve, sign and pay.</p><ol class="gd-flow"><li><b>1</b><span>Request</span><em>You pick a car and dates</em></li><li><b>2</b><span>Offer</span><em>We confirm the price</em></li><li><b>3</b><span>Sign</span><em>The rental agreement</em></li><li><b>4</b><span>Pay</span><em>Your card is authorized</em></li><li><b>5</b><span>Verify</span><em>Licence, selfie, coverage</em></li><li><b>6</b><span>Pick up</span><em>We hand over the keys</em></li></ol><section class="gd-task" id="find-a-car-and-send-a-request-find-a-car" data-gd-task><h2 class="gd-h2">Find a car</h2><p class="gd-p">Start on carmacars.ca. You do not need to sign in to look around.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Go to <span class="gd-url">carmacars.ca</span> and press <b class="gd-ui">Find a car</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Add your pickup and return dates. The list then shows the cars that are free and what the whole trip costs.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Narrow the list with Filters: type, seats, transmission and daily rate.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Open a car to see its photos, rates, what is included and its own calendar. Its car code (like CC-7F3A) is under the price: quote it when you call or chat with us, and we know the car at once.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/cars</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/880"><img src="/guides/img/public-02-cars-desktop-b6cd4fb8.jpg" alt="" loading="lazy" decoding="async" width="1440" height="880"><span class="gd-pin" style="left:86.1%;top:4%" aria-hidden="true">1</span><span class="gd-pin" style="left:11.1%;top:56.8%" aria-hidden="true">2</span><span class="gd-pin" style="left:3%;top:82.3%" aria-hidden="true">3</span><span class="gd-pin" style="left:34%;top:87.5%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="find-a-car-and-send-a-request-choose-your-dates-on-the-car-page" data-gd-task><h2 class="gd-h2">Choose your dates on the car page</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Under Dates and price, tap your pickup date, then your return date. Hatched days are already booked.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose the Pickup time and the Return time.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Want it brought to you? Tick <b class="gd-ui">Deliver it to me</b> or <b class="gd-ui">Pick it up from me at the end</b>. Open Add-ons to add a baby seat, flowers, a full tank and more.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Check Your estimate, then press <b class="gd-ui">Request to book</b>. The add-ons you chose come with you.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/cars/bmw-330i</span></div><div class="gd-imgwrap" style="aspect-ratio:1120/760"><img src="/guides/img/public-03-car-page-desktop-73be4d63.jpg" alt="" loading="lazy" decoding="async" width="1120" height="760"><span class="gd-pin" style="left:24.4%;top:39.7%" aria-hidden="true">1</span><span class="gd-pin" style="left:12.9%;top:68.2%" aria-hidden="true">2</span><span class="gd-pin" style="left:3%;top:76.2%" aria-hidden="true">3</span><span class="gd-pin" style="left:97%;top:50%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>A request does not hold the car. The car is booked only once you approve the offer, sign and pay.</div></aside></section><section class="gd-task" id="find-a-car-and-send-a-request-send-your-request" data-gd-task><h2 class="gd-h2">Send your request</h2><p class="gd-p">The request has five short steps. Your answers are saved as you go, so you can come back.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Step 1, Dates and delivery: check the car and tap your dates in the calendar.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Set the Pickup time and Return time. Any time, day or night, with at least 2 hours of notice.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Your request, on the right, shows the estimated total as you go.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/book/bmw-330i?from=2026-11-25&amp;to=2026-11-28&amp;tf=10:00&amp;tt=10:00</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1002"><img src="/guides/img/public-04-book-1-trip-desktop-63a3738b.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1002"><span class="gd-pin" style="left:9.2%;top:67.1%" aria-hidden="true">1</span><span class="gd-pin" style="left:15.3%;top:91%" aria-hidden="true">2</span><span class="gd-pin" style="left:91.1%;top:54.7%" aria-hidden="true">3</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="4"><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Choose where you get the car: <b class="gd-ui">At our location</b>, <b class="gd-ui">Deliver it to an address</b> or <b class="gd-ui">At the airport</b>. Then choose where you return it.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press <b class="gd-ui">Continue to driver details</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/book/bmw-330i?from=2026-11-25&amp;to=2026-11-28&amp;tf=10:00&amp;tt=10:00</span></div><div class="gd-imgwrap" style="aspect-ratio:760/942"><img src="/guides/img/public-04-book-1-trip-desktop-befba4f6.jpg" alt="" loading="lazy" decoding="async" width="760" height="942"><span class="gd-pin" style="left:5.3%;top:26.2%" aria-hidden="true">4</span><span class="gd-pin" style="left:61.8%;top:93.3%" aria-hidden="true">5</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="6"><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Step 2, The driver: fill in your first and last name, email, mobile number and date of birth.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Someone else will drive too? Add them under Additional drivers. Each needs a G2 or G licence and signs the agreement.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Press <b class="gd-ui">Continue to licence</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/book/bmw-330i?from=2026-11-25&amp;to=2026-11-28&amp;tf=10:00&amp;tt=10:00</span></div><div class="gd-imgwrap" style="aspect-ratio:980/1032"><img src="/guides/img/public-05-book-2-driver-desktop-7b572499.jpg" alt="" loading="lazy" decoding="async" width="980" height="1032"><span class="gd-pin" style="left:30.6%;top:21.1%" aria-hidden="true">6</span><span class="gd-pin" style="left:30.6%;top:64.8%" aria-hidden="true">7</span><span class="gd-pin" style="left:55.6%;top:88%" aria-hidden="true">8</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="9"><li><span class="gd-n" aria-hidden="true">9</span><div class="gd-t">Step 3: choose your Licence class, for example Ontario G2.</div></li><li><span class="gd-n" aria-hidden="true">10</span><div class="gd-t">Choose how the car is covered: Option 1 (OPCF 27 on your own auto policy), Option 2 (rental coverage on your credit card) or Option 3 (the CarmaCars Protection Plan). You can change this any time before pickup. You may also see a link to RentalCoverage, a separate company&#39;s optional product. It is not issued or handled by CarmaCars and does not replace the option you choose here, and we may earn a commission if you buy it, at no extra cost to you.</div></li><li><span class="gd-n" aria-hidden="true">11</span><div class="gd-t">Choose the Booking type: Standard, or Non-refundable for 10% off with no refund.</div></li><li><span class="gd-n" aria-hidden="true">12</span><div class="gd-t">Add anything we should know in the notes, for example a flight number. If a body shop, a tow company or a friend sent you, type their name or the referral code from their card in Did someone refer you?.</div></li><li><span class="gd-n" aria-hidden="true">13</span><div class="gd-t">Press <b class="gd-ui">Continue to add-ons</b>. Step 4, Add-ons: tick what you want (see Add-ons below), then press <b class="gd-ui">Review request</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/book/bmw-330i?from=2026-11-25&amp;to=2026-11-28&amp;tf=10:00&amp;tt=10:00</span></div><div class="gd-imgwrap" style="aspect-ratio:760/1452"><img src="/guides/img/public-06-book-3-licence-desktop-22bb144e.jpg" alt="" loading="lazy" decoding="async" width="760" height="1452"><span class="gd-pin" style="left:61.8%;top:11.2%" aria-hidden="true">9</span><span class="gd-pin" style="left:92.1%;top:32.2%" aria-hidden="true">10</span><span class="gd-pin" style="left:92.1%;top:50.4%" aria-hidden="true">11</span><span class="gd-pin" style="left:92.1%;top:66.9%" aria-hidden="true">12</span><span class="gd-pin" style="left:71.7%;top:97%" aria-hidden="true">13</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="14"><li><span class="gd-n" aria-hidden="true">14</span><div class="gd-t">Step 5, Check it and send: read every line. Use Edit beside a line to change it.</div></li><li><span class="gd-n" aria-hidden="true">15</span><div class="gd-t">Tick the box to confirm you are 18 or older and agree to the Terms of use and Privacy policy.</div></li><li><span class="gd-n" aria-hidden="true">16</span><div class="gd-t">Press <b class="gd-ui">Send request</b>. Nothing is charged and no card is needed.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/book/bmw-330i?from=2026-11-25&amp;to=2026-11-28&amp;tf=10:00&amp;tt=10:00</span></div><div class="gd-imgwrap" style="aspect-ratio:760/492"><img src="/guides/img/public-07-book-4-review-desktop-005f4c0b.jpg" alt="" loading="lazy" decoding="async" width="760" height="492"><span class="gd-pin" style="left:92.1%;top:24.8%" aria-hidden="true">14</span><span class="gd-pin" style="left:3.9%;top:59.3%" aria-hidden="true">15</span><span class="gd-pin" style="left:73.7%;top:89%" aria-hidden="true">16</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol" start="17"><li><span class="gd-n" aria-hidden="true">17</span><div class="gd-t">The confirmation shows your request number, for example CC-10021. Keep it for any question.</div></li><li><span class="gd-n" aria-hidden="true">18</span><div class="gd-t">A person checks the calendar, your dates and your place, usually within 2 hours, day or night. Your offer arrives by email and in Trips.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/755"><img src="/guides/img/public-08-book-5-sent-phone-14a99ccf.jpg" alt="" loading="lazy" decoding="async" width="390" height="755"><span class="gd-pin" style="left:32.8%;top:12.3%" aria-hidden="true">17</span></div></div></figure></div></section><section class="gd-task" id="find-a-car-and-send-a-request-upload-your-licence" data-gd-task><h2 class="gd-h2">Upload your licence</h2><p class="gd-p">Right after you send your request: the front and back of your licence and a selfie holding it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On the Request sent page, press <b class="gd-ui">Upload your licence</b> (or open your booking and press <b class="gd-ui">Your licence</b>).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Take each photo with your phone, or choose it. Add the licence number and expiry date if we ask: it must be valid after your return.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Rented with us before? A licence on file that is still valid is used again; nothing to upload.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>You need your licence on file to accept the offer.</div></aside></section><section class="gd-task" id="find-a-car-and-send-a-request-add-ons" data-gd-task><h2 class="gd-h2">Add-ons</h2><p class="gd-p">Extras for your trip, such as a baby seat, a child or booster seat, flowers waiting in the car, a chauffeur, an umbrella, a phone charger or a full tank of gas.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On the car page (under Add-ons) or in step 4 of the request, tick an add-on or use + and − for seats. The estimate shows the price at once.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each add-on shows its price: a trip, a day (with the most for a trip) or an hour. HST is added.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Some need notice, for example flowers need 24 hours. Seats and other items show how many are left for your dates.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A chauffeur is confirmed by our team in your offer.</div></li></ol></div><p class="gd-p">With a full tank of gas (prepaid) you can return the car at any fuel level, with no fuel charge.</p></section><section class="gd-task" id="find-a-car-and-send-a-request-a-discount-code" data-gd-task><h2 class="gd-h2">A discount code</h2><p class="gd-p">A code from a game on the site, an offer we sent you, or from our team.</p><ul class="gd-ul"><li>On the last step of your request, type it in the promo code box. The price shows the discount at once.</li><li>Every code has a last day. You find it in the email or text that brought the code, and under Your discount codes on Your trips.</li><li>If you have not used a code, we remind you 3 days before its last day and the day before, by email and text as you chose in Profile. A code you won in a game is always reminded; a reminder of an offer comes only if you agreed to get offers, and every email has an Unsubscribe link.</li><li>A code that ended is refused with &quot;This code has expired&quot;. You can still send the request without it.</li></ul></section><section class="gd-task" id="find-a-car-and-send-a-request-ask-in-the-chat" data-gd-task><h2 class="gd-h2">Ask in the chat</h2><p class="gd-p">The chat button sits in the corner of every page.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press it and write your question: a car, your dates, the price, how booking works. The CarmaCars assistant answers right away with prices from our booking system.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Want a person? Press <b class="gd-ui">Talk to a person</b>. When our team is away, leave your name and email or phone with <b class="gd-ui">Send my details</b> and tick &quot;Email me a copy of this chat&quot;.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">End chat</b> when you are done. If you gave your email, a copy of the chat arrives by email.</div></li></ol></div><p class="gd-p">A price in the chat is for the dates you asked. Nothing is booked until you approve an offer, sign and pay.</p></section><section class="gd-task" id="find-a-car-and-send-a-request-carry-on-later" data-gd-task><h2 class="gd-h2">Carry on later</h2><ul class="gd-ul"><li>Your name, email and mobile number are saved as you type them, so nothing is lost if you stop. We open an account for you with that email.</li><li>Every form that saves as you type says so under it: &quot;Saved as you type so you can pick up where you left off.&quot;, with a link to the privacy policy.</li><li>On the same phone or computer, open <span class="gd-url">carmacars.ca/account</span> (or the request page again) to carry on, no password needed.</li><li>We send you one email, &quot;Continue your request&quot;. One tap signs you in, confirms your email and opens your request on any device. You need it before you can accept an offer, sign or pay.</li><li>Already have an account? The form says &quot;You have an account: we sent you a sign-in link&quot;.</li></ul></section>');
select app.guide_release_section('admin', 'referral-partners-and-rentalcoverage', 'chapter', 'discount-games-and-leads', null, 'Referral partners and RentalCoverage', 'Body shops and tow trucks that send renters: sign-ups, links and flyers, earnings and payments; and the optional RentalCoverage link.',
  'Body shops and tow truck companies (and, if you want, dealerships and insurance brokers) can send you renters and earn a kickback when the rental is finished and paid in full. A separate switch adds an optional affiliate link to RentalCoverage on the pages that talk about coverage. Nothing in either program is shown to renters until you set it up.

## Add a partner

**People** > **Referral partners**, then **Add a partner**.

1. Choose the kind (body shop, tow truck company, dealership or insurance broker) and type the business name, the contact, phone and email. Start typing the address: the city and postal code fill in.
2. Choose how you pay them (e-Transfer, cheque, bank transfer, cash or another way) and, for e-Transfer, the email to pay.
3. Choose the kickback: a flat amount for each completed rental ($50 unless you change it) or a percentage of the rental charge (10% unless you change it). The percentage applies to the rental charge after discounts only, never to add-ons, fees or taxes. The two defaults are under **Settings** > **Program**, Referral partners.
4. Press **Save**. A partner you add is active at once, with a code, a short link and a flyer.

## Approve a sign-up

The public pages carmacars.ca/partners/body-shops and carmacars.ca/partners/tow-trucks have a sign-up form. A sign-up is a pending partner and a task for you; it earns nothing and its code ties no rental until you approve it.

1. Open **People** > **Referral partners**. A sign-up shows as Waiting for approval, and the Partners tab shows how many are waiting.
2. Open the partner and check the business. Press **Approve** (or **Decline**: they are not told by email).
3. Press **Write them their link**. It opens an email to them with their link and code; attach the flyer from the next section before you send it.

## The link, the QR code and the flyer

Open the partner. The card "Link, QR code and flyer" shows everything they hand out.

- The short link is carmacars.ca/r/ and their code, for example carmacars.ca/r/BODY1234. A renter who opens it keeps the partner for 60 days on that device, even if they book later.
- Press **Flyer for the counter (PDF)** for a one-page flyer with their name, their code and a QR code of the link. Print it or send it.
- A renter can also type the code in "Did someone refer you?" on the request to book. A code typed there wins over the link. A code nobody holds is ignored.
- Changing the code ends the old link, QR code and flyer. Pausing or ending a partner stops new rentals from being tied to them; what they already earned stays.

## Rentals you add by hand

**Bookings** > **Add a rental**, field "Referred by (partner code)".

1. Type the partner''s code if a body shop or tow truck sent the renter. A code that does not exist or is not active is refused, so a typing mistake shows at once.
2. Forgot it? Open the partner and press **Tie a booking**: enter the booking number and why. This is not possible once a kickback on that booking is approved or paid, nor on a booking that already has an owner or field staff member as its referrer (one referrer per booking: owner, then field staff, then the partner).

## Earnings and payments

**People** > **Referral partners**, the tabs Partners, Kickbacks and Payments made.

1. A kickback starts as "Rental not finished yet". It is earned when the booking is completed and paid in full and no payment is in dispute; it then waits as "Pending approval".
2. Check it on the Kickbacks tab and press **Approve** (or **Approve all** for one partner).
3. Pay the partner the way you agreed, then press **Record a payment** on their line: it settles every approved kickback and keeps the reference.
4. A refund or a lost dispute after the kickback was earned takes it back (a reversal line). If it was already paid, the reversal stays on the ledger as a negative line for you to settle with the partner. Use **Reverse** to take one back yourself, with a reason.

> Good to know: The kickback is a booking expense, taken before the owner''s share is worked out, in the same line as staff commissions on the owner statement. Check the owner agreement wording on kickbacks before you start paying partners.

## The partner''s own page

The card "Link, QR code and flyer" shows a private page address for the partner. Send it only to them.

- It shows their link and code, their referrals by the customer''s first name and the month only, what is waiting and what was paid. No sign-in: the long address is the key.
- Press **New private page link** if it was shared by mistake: the old address stops working at once.

## RentalCoverage affiliate

**Settings** > **RentalCoverage affiliate**. It is off until you join the affiliate program and paste your link.

1. Join RentalCoverage''s affiliate program (their affiliate dashboard gives you a tracking link, and sometimes an ID).
2. Press **Paste the affiliate link**. Paste the link exactly as the dashboard gives it. If it has {id} in it, type your ID in the next field and it is filled in. Leave "Show the link on the site" ticked and press **Save**.
3. The link now shows on Requirements and coverage, the credit card coverage guide and the coverage step of the request to book. Each says it is a separate company''s optional product, that it does not replace the coverage option the renter chooses, that CarmaCars may earn a commission and that it costs the renter nothing extra. It says nothing about what the product covers.
4. Untick "Show the link on the site" any time to turn it off everywhere.

- Every click goes through a CarmaCars address that counts it by place and month (and by booking when the renter has one) and adds utm_source=carmacars, utm_medium=referral and utm_campaign=coverage_ and the place.
- The page shows clicks by place and month and the latest clicks. RentalCoverage reports the sales, not the site: when they pay you, press **Add a payment received** with the date, amount and reference.',
  '<p class="gd-p">Body shops and tow truck companies (and, if you want, dealerships and insurance brokers) can send you renters and earn a kickback when the rental is finished and paid in full. A separate switch adds an optional affiliate link to RentalCoverage on the pages that talk about coverage. Nothing in either program is shown to renters until you set it up.</p><section class="gd-task" id="referral-partners-and-rentalcoverage-add-a-partner" data-gd-task><h2 class="gd-h2">Add a partner</h2><p class="gd-p"><b class="gd-ui">People</b> &gt; <b class="gd-ui">Referral partners</b>, then <b class="gd-ui">Add a partner</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Choose the kind (body shop, tow truck company, dealership or insurance broker) and type the business name, the contact, phone and email. Start typing the address: the city and postal code fill in.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose how you pay them (e-Transfer, cheque, bank transfer, cash or another way) and, for e-Transfer, the email to pay.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Choose the kickback: a flat amount for each completed rental ($50 unless you change it) or a percentage of the rental charge (10% unless you change it). The percentage applies to the rental charge after discounts only, never to add-ons, fees or taxes. The two defaults are under <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Program</b>, Referral partners.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Save</b>. A partner you add is active at once, with a code, a short link and a flyer.</div></li></ol></div></section><section class="gd-task" id="referral-partners-and-rentalcoverage-approve-a-sign-up" data-gd-task><h2 class="gd-h2">Approve a sign-up</h2><p class="gd-p">The public pages carmacars.ca/partners/body-shops and carmacars.ca/partners/tow-trucks have a sign-up form. A sign-up is a pending partner and a task for you; it earns nothing and its code ties no rental until you approve it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">People</b> &gt; <b class="gd-ui">Referral partners</b>. A sign-up shows as Waiting for approval, and the Partners tab shows how many are waiting.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open the partner and check the business. Press <b class="gd-ui">Approve</b> (or <b class="gd-ui">Decline</b>: they are not told by email).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Write them their link</b>. It opens an email to them with their link and code; attach the flyer from the next section before you send it.</div></li></ol></div></section><section class="gd-task" id="referral-partners-and-rentalcoverage-the-link-the-qr-code-and-the-flyer" data-gd-task><h2 class="gd-h2">The link, the QR code and the flyer</h2><p class="gd-p">Open the partner. The card &quot;Link, QR code and flyer&quot; shows everything they hand out.</p><ul class="gd-ul"><li>The short link is carmacars.ca/r/ and their code, for example carmacars.ca/r/BODY1234. A renter who opens it keeps the partner for 60 days on that device, even if they book later.</li><li>Press <b class="gd-ui">Flyer for the counter (PDF)</b> for a one-page flyer with their name, their code and a QR code of the link. Print it or send it.</li><li>A renter can also type the code in &quot;Did someone refer you?&quot; on the request to book. A code typed there wins over the link. A code nobody holds is ignored.</li><li>Changing the code ends the old link, QR code and flyer. Pausing or ending a partner stops new rentals from being tied to them; what they already earned stays.</li></ul></section><section class="gd-task" id="referral-partners-and-rentalcoverage-rentals-you-add-by-hand" data-gd-task><h2 class="gd-h2">Rentals you add by hand</h2><p class="gd-p"><b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Add a rental</b>, field &quot;Referred by (partner code)&quot;.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Type the partner&#39;s code if a body shop or tow truck sent the renter. A code that does not exist or is not active is refused, so a typing mistake shows at once.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Forgot it? Open the partner and press <b class="gd-ui">Tie a booking</b>: enter the booking number and why. This is not possible once a kickback on that booking is approved or paid, nor on a booking that already has an owner or field staff member as its referrer (one referrer per booking: owner, then field staff, then the partner).</div></li></ol></div></section><section class="gd-task" id="referral-partners-and-rentalcoverage-earnings-and-payments" data-gd-task><h2 class="gd-h2">Earnings and payments</h2><p class="gd-p"><b class="gd-ui">People</b> &gt; <b class="gd-ui">Referral partners</b>, the tabs Partners, Kickbacks and Payments made.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A kickback starts as &quot;Rental not finished yet&quot;. It is earned when the booking is completed and paid in full and no payment is in dispute; it then waits as &quot;Pending approval&quot;.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Check it on the Kickbacks tab and press <b class="gd-ui">Approve</b> (or <b class="gd-ui">Approve all</b> for one partner).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Pay the partner the way you agreed, then press <b class="gd-ui">Record a payment</b> on their line: it settles every approved kickback and keeps the reference.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A refund or a lost dispute after the kickback was earned takes it back (a reversal line). If it was already paid, the reversal stays on the ledger as a negative line for you to settle with the partner. Use <b class="gd-ui">Reverse</b> to take one back yourself, with a reason.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>The kickback is a booking expense, taken before the owner&#39;s share is worked out, in the same line as staff commissions on the owner statement. Check the owner agreement wording on kickbacks before you start paying partners.</div></aside></section><section class="gd-task" id="referral-partners-and-rentalcoverage-the-partner-s-own-page" data-gd-task><h2 class="gd-h2">The partner&#39;s own page</h2><p class="gd-p">The card &quot;Link, QR code and flyer&quot; shows a private page address for the partner. Send it only to them.</p><ul class="gd-ul"><li>It shows their link and code, their referrals by the customer&#39;s first name and the month only, what is waiting and what was paid. No sign-in: the long address is the key.</li><li>Press <b class="gd-ui">New private page link</b> if it was shared by mistake: the old address stops working at once.</li></ul></section><section class="gd-task" id="referral-partners-and-rentalcoverage-rentalcoverage-affiliate" data-gd-task><h2 class="gd-h2">RentalCoverage affiliate</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">RentalCoverage affiliate</b>. It is off until you join the affiliate program and paste your link.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Join RentalCoverage&#39;s affiliate program (their affiliate dashboard gives you a tracking link, and sometimes an ID).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Paste the affiliate link</b>. Paste the link exactly as the dashboard gives it. If it has {id} in it, type your ID in the next field and it is filled in. Leave &quot;Show the link on the site&quot; ticked and press <b class="gd-ui">Save</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The link now shows on Requirements and coverage, the credit card coverage guide and the coverage step of the request to book. Each says it is a separate company&#39;s optional product, that it does not replace the coverage option the renter chooses, that CarmaCars may earn a commission and that it costs the renter nothing extra. It says nothing about what the product covers.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Untick &quot;Show the link on the site&quot; any time to turn it off everywhere.</div></li></ol></div><ul class="gd-ul"><li>Every click goes through a CarmaCars address that counts it by place and month (and by booking when the renter has one) and adds utm_source=carmacars, utm_medium=referral and utm_campaign=coverage_ and the place.</li><li>The page shows clicks by place and month and the latest clicks. RentalCoverage reports the sales, not the site: when they pay you, press <b class="gd-ui">Add a payment received</b> with the date, amount and reference.</li></ul></section>');
-- GUIDES 0164 END
