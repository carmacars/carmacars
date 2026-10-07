-- 0007_owner_billing.sql
-- Owner fee invoices (one per vehicle), prepaid first/last month, late fees and arrears,
-- other deductions, referral kickbacks, the booking split, monthly owner statements and payouts.
-- Source: docs/source/owner_billing_spec.md (sections cited inline).

-- ---------------------------------------------------------------- business dates (Toronto)
-- p_month is any date in the month concerned.
create or replace function app.billing_date(p_month date) returns date
language sql stable as $$
  select app.month_start(p_month) + ((app.settings(app.month_start(p_month))).billing_day - 1)
$$;
create or replace function app.retry_date(p_month date) returns date
language sql stable as $$
  select app.month_start(p_month) + ((app.settings(app.month_start(p_month))).retry_day - 1)
$$;
-- The statement for month M is paid on the 10th of month M + 1.
create or replace function app.payout_date(p_statement_month date) returns date
language sql stable as $$
  select (app.month_start(p_statement_month) + interval '1 month')::date
         + ((app.settings((app.month_start(p_statement_month) + interval '1 month')::date)).payout_day - 1)
$$;

-- The last day a vehicle's Fees run: its Exit Date or, on a total loss, the Insurer's decision date.
create or replace function app.vehicle_fee_end(p_vehicle uuid) returns date
language sql stable security definer set search_path = public, app as $$
  select case when exit_date is null then total_loss_decided_on
              when total_loss_decided_on is null then exit_date
              else least(exit_date, total_loss_decided_on) end
    from vehicles where id = p_vehicle
$$;

-- Days of a calendar month in which Fees run. Both the Enrollment Date and the Exit Date count.
create or replace function public.calc_fee_days(p_month date, p_enrollment date, p_fee_end date)
returns integer language sql immutable as $$
  select greatest(0,
           (least(coalesce(p_fee_end, 'infinity'::date), (date_trunc('month', p_month) + interval '1 month - 1 day')::date)
            - greatest(p_enrollment, date_trunc('month', p_month)::date)) + 1)::integer
$$;

-- ---------------------------------------------------------------- owner fee invoices (sections 1, 4, 6)
create sequence owner_invoice_number_seq start 1001;
create sequence owner_statement_number_seq start 1001;

create table owner_invoices (
  id               uuid primary key default gen_random_uuid(),
  invoice_number   text not null unique default ('INV-' || nextval('owner_invoice_number_seq')),
  owner_id         uuid not null references owners (id),
  vehicle_id       uuid not null references vehicles (id),   -- each vehicle has its own invoice and debit
  kind             text not null check (kind in ('upfront', 'monthly', 'adjustment')),
  period_month     date check (extract(day from period_month) = 1),  -- the calendar month the Fees cover
  days_billed      integer,
  days_in_month    integer,
  billing_date     date not null,                    -- the 15th; upfront: the day it is issued
  retry_on         date,                             -- the 18th
  payment_method   text not null default 'pre_authorized_debit'
                   check (payment_method in ('pre_authorized_debit', 'card', 'e_transfer')),
  status           text not null default 'draft' check (status in (
                     'draft', 'issued', 'processing', 'paid', 'failed', 'retry_processing',
                     'in_arrears', 'partially_deducted', 'deducted', 'void')),
  fees_cents       bigint not null default 0,        -- taxable lines, credits included (may net to less than a full month)
  hst_cents        bigint not null default 0,
  late_fee_cents   bigint not null default 0,        -- no HST
  total_cents      bigint generated always as (fees_cents + hst_cents + late_fee_cents) stored,
  paid_cents       bigint not null default 0 check (paid_cents >= 0),
  deducted_cents   bigint not null default 0 check (deducted_cents >= 0),  -- taken from revenue at a payout
  balance_cents    bigint generated always as (fees_cents + hst_cents + late_fee_cents - paid_cents - deducted_cents) stored,
  issued_at        timestamptz,
  first_failed_on  date,
  retry_failed_on  date,
  removal_allowed_on date,                           -- 30 days after the failed retry
  paid_at          timestamptz,
  notified_at      timestamptz,                      -- T24 / T25
  document_id      uuid references documents (id),
  created_by       uuid references users (id),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  check (kind <> 'monthly' or period_month is not null),
  check (paid_cents + deducted_cents <= fees_cents + hst_cents + late_fee_cents or fees_cents + hst_cents + late_fee_cents < 0)
);
create unique index owner_invoices_one_per_month on owner_invoices (vehicle_id, period_month)
  where kind = 'monthly' and status <> 'void';
create unique index owner_invoices_one_upfront on owner_invoices (vehicle_id) where kind = 'upfront' and status <> 'void';
create index owner_invoices_owner_idx on owner_invoices (owner_id, period_month);
create index owner_invoices_status_idx on owner_invoices (status, billing_date);
create trigger owner_invoices_updated before update on owner_invoices for each row execute function app.set_updated_at();

create table owner_invoice_lines (
  id               uuid primary key default gen_random_uuid(),
  owner_invoice_id uuid not null references owner_invoices (id) on delete cascade,
  kind             text not null check (kind in (
                     'install_fee', 'first_month_insurance', 'last_month_insurance',
                     'insurance_fee', 'tracker_fee', 'late_fee', 'prepaid_credit', 'adjustment')),
  description      text,
  amount_cents     bigint not null,                  -- before HST; negative for a credit
  hst_applies      boolean not null,
  hst_cents        bigint not null default 0,
  vehicle_prepaid_id uuid,                           -- the prepaid this credit draws on
  created_at       timestamptz not null default now(),
  check (hst_applies or hst_cents = 0),
  check (kind <> 'late_fee' or not hst_applies),     -- no HST on a Late Fee
  check (kind <> 'prepaid_credit' or amount_cents <= 0)
);
create index owner_invoice_lines_invoice_idx on owner_invoice_lines (owner_invoice_id);

create or replace function app.owner_invoice_recalc() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid := coalesce(new.owner_invoice_id, old.owner_invoice_id);
begin
  update owner_invoices i
     set fees_cents = coalesce((select sum(amount_cents) from owner_invoice_lines l where l.owner_invoice_id = v_id and l.kind <> 'late_fee'), 0),
         hst_cents = coalesce((select sum(hst_cents) from owner_invoice_lines l where l.owner_invoice_id = v_id), 0),
         late_fee_cents = coalesce((select sum(amount_cents) from owner_invoice_lines l where l.owner_invoice_id = v_id and l.kind = 'late_fee'), 0)
   where i.id = v_id;
  return null;
end $$;
create trigger owner_invoice_lines_recalc after insert or update or delete on owner_invoice_lines
  for each row execute function app.owner_invoice_recalc();

-- Prepaid first and last month's Insurance Fee, per vehicle (liability until used or refunded).
create table vehicle_prepaids (
  id              uuid primary key default gen_random_uuid(),
  vehicle_id      uuid not null references vehicles (id),
  owner_id        uuid not null references owners (id),
  kind            text not null check (kind in ('first_month_insurance', 'last_month_insurance')),
  amount_cents    bigint not null check (amount_cents >= 0),   -- before HST
  hst_cents       bigint not null default 0,
  applied_cents   bigint not null default 0 check (applied_cents >= 0),   -- used against Insurance Fee lines (before HST)
  refunded_cents  bigint not null default 0 check (refunded_cents >= 0),  -- unused part refunded on exit (before HST)
  remaining_cents bigint generated always as (amount_cents - applied_cents - refunded_cents) stored,
  source_invoice_id uuid references owner_invoices (id),
  refund_due_since date,
  refunded_at     timestamptz,
  created_at      timestamptz not null default now(),
  unique (vehicle_id, kind),
  check (applied_cents + refunded_cents <= amount_cents)
);
alter table owner_invoice_lines add constraint owner_invoice_lines_prepaid_fk
  foreign key (vehicle_prepaid_id) references vehicle_prepaids (id);

alter table vehicle_onboardings add constraint vehicle_onboardings_upfront_invoice_fk
  foreign key (upfront_invoice_id) references owner_invoices (id);
alter table payments add constraint payments_owner_invoice_fk
  foreign key (owner_invoice_id) references owner_invoices (id);
create index payments_owner_invoice_idx on payments (owner_invoice_id);

-- What follows from an invoice changing status. Which changes are allowed is in 0011.
create or replace function app.owner_invoice_status_stamp() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_set program_settings := app.settings(coalesce(new.billing_date, app.today()));
begin
  if new.status = old.status then return new; end if;
  if new.status = 'issued' and new.issued_at is null then new.issued_at := now(); end if;
  if new.status = 'failed' then
    new.first_failed_on := coalesce(new.first_failed_on, app.today());
    new.retry_on := coalesce(new.retry_on, app.retry_date(new.billing_date));
    new.paid_cents := 0;          -- a debit returned after it showed as paid
    new.paid_at := null;
  end if;
  if new.status = 'in_arrears' then
    new.retry_failed_on := coalesce(new.retry_failed_on, app.today());
    new.removal_allowed_on := new.retry_failed_on + v_set.owner_arrears_removal_days;
  end if;
  if new.status in ('paid', 'deducted') then
    new.paid_at := coalesce(new.paid_at, now());
    -- (generated columns are not yet computed in a BEFORE trigger, so the total is spelled out)
    if new.status = 'paid' then
      new.paid_cents := new.fees_cents + new.hst_cents + new.late_fee_cents - new.deducted_cents;
    end if;
  end if;
  return new;
end $$;
create trigger owner_invoices_status_stamp before update of status on owner_invoices
  for each row execute function app.owner_invoice_status_stamp();

create or replace function app.owner_invoice_status_effects() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_set program_settings := app.settings(coalesce(new.billing_date, app.today()));
begin
  if new.status = old.status then return null; end if;

  -- 15th: the debit fails. Add the $50 Late Fee to the vehicle affected, once per missed payment.
  if new.status = 'failed'
     and not exists (select 1 from owner_invoice_lines l where l.owner_invoice_id = new.id and l.kind = 'late_fee') then
    insert into owner_invoice_lines (owner_invoice_id, kind, description, amount_cents, hst_applies)
    values (new.id, 'late_fee', 'Late Fee: missed payment', v_set.owner_late_fee_cents, false);
  end if;

  -- 18th: the retry fails. The vehicle is in arrears; a Self-Managed vehicle takes no new bookings
  -- (app.vehicle_bookable() in 0011 reads the flag).
  if new.status = 'in_arrears' then
    update vehicles set in_arrears = true where id = new.vehicle_id and not in_arrears;
    insert into tasks (queue, task_type, title, detail, procedure_no, priority, vehicle_id, owner_id,
                       related_table, related_id, escalated, escalated_at, escalation_reason)
    values ('admin', 'owner_retry_failed', 'Owner fee retry failed',
            format('Invoice %s is in arrears. Deduct at the next payout; removal is allowed from %s.', new.invoice_number, new.removal_allowed_on),
            14, 'high', new.vehicle_id, new.owner_id, 'owner_invoices', new.id, true, now(), 'retry fails');
  end if;

  if new.status in ('paid', 'deducted') then
    if not exists (select 1 from owner_invoices o where o.vehicle_id = new.vehicle_id and o.id <> new.id
                    and o.status in ('in_arrears', 'partially_deducted')) then
      update vehicles set in_arrears = false where id = new.vehicle_id and in_arrears;
    end if;
    -- the upfront invoice funds the two prepaid months
    if new.kind = 'upfront' then
      insert into vehicle_prepaids (vehicle_id, owner_id, kind, amount_cents, hst_cents, source_invoice_id)
      select new.vehicle_id, new.owner_id, l.kind, l.amount_cents, l.hst_cents, new.id
        from owner_invoice_lines l
       where l.owner_invoice_id = new.id and l.kind in ('first_month_insurance', 'last_month_insurance')
      on conflict (vehicle_id, kind) do nothing;
    end if;
  end if;
  return null;
end $$;
create trigger owner_invoices_status_effects after update of status on owner_invoices
  for each row execute function app.owner_invoice_status_effects();

-- Upfront invoice (section 1): the $100 Install Fee and first and last month's Insurance Fee.
-- Never issued for a Turo-Only or shareholder-owned vehicle. Onboarding costs are not billed.
create or replace function app.issue_upfront_invoice(p_vehicle uuid, p_by uuid default null)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  s vehicle_schedules;
  v_hst integer := (app.settings()).hst_bps;
  v_id uuid;
begin
  select * into v from vehicles where id = p_vehicle;
  if v.billing_case in ('turo_only', 'shareholder') then
    raise exception 'No upfront charges apply to a % vehicle', v.billing_case using errcode = '23514';
  end if;
  select * into s from vehicle_schedules where vehicle_id = p_vehicle and superseded_by is null;
  if s.id is null then
    raise exception 'Vehicle % has no signed Vehicle Schedule', p_vehicle using errcode = '23514';
  end if;
  insert into owner_invoices (owner_id, vehicle_id, kind, billing_date, payment_method, status, created_by)
  values (v.owner_id, p_vehicle, 'upfront', app.today(), 'card', 'draft', p_by) returning id into v_id;
  insert into owner_invoice_lines (owner_invoice_id, kind, description, amount_cents, hst_applies, hst_cents) values
    (v_id, 'install_fee', 'Tracker Install Fee', s.install_fee_cents, true, public.calc_hst(s.install_fee_cents, v_hst)),
    (v_id, 'first_month_insurance', 'First month''s Insurance Fee', s.insurance_fee_cents, true, public.calc_hst(s.insurance_fee_cents, v_hst)),
    (v_id, 'last_month_insurance', 'Last month''s Insurance Fee', s.insurance_fee_cents, true, public.calc_hst(s.insurance_fee_cents, v_hst));
  update vehicle_onboardings set upfront_invoice_id = v_id where vehicle_id = p_vehicle;
  return v_id;
end $$;

-- Monthly invoice for one vehicle and one calendar month (sections 1 and 9).
-- Returns null when no Fees run in that month or the invoice already exists.
create or replace function app.generate_owner_invoice(p_vehicle uuid, p_month date, p_by uuid default null)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  v_month date := app.month_start(p_month);
  v_end date;
  v_days integer;
  v_dim integer := app.days_in_month(p_month);
  t vehicle_fee_history;
  v_hst integer := (app.settings(v_month)).hst_bps;
  v_ins bigint;
  v_trk bigint;
  v_id uuid;
  v_left bigint;
  v_use bigint;
  p vehicle_prepaids;
begin
  select * into v from vehicles where id = p_vehicle;
  if v.billing_case in ('turo_only', 'shareholder') or v.enrollment_date is null then return null; end if;
  v_end := app.vehicle_fee_end(p_vehicle);
  v_days := public.calc_fee_days(v_month, v.enrollment_date, v_end);
  if v_days <= 0 then return null; end if;
  if exists (select 1 from owner_invoices where vehicle_id = p_vehicle and period_month = v_month
               and kind = 'monthly' and status <> 'void') then
    return null;
  end if;
  -- the terms in force on the billing date (or the nearest day in the month on which Fees ran)
  t := app.vehicle_terms(p_vehicle, least(greatest(app.billing_date(v_month), v.enrollment_date), coalesce(v_end, 'infinity'::date)));
  if t.id is null then
    raise exception 'Vehicle % has no fee terms for %', p_vehicle, v_month using errcode = '23514';
  end if;
  v_ins := public.calc_prorated_fee(t.insurance_fee_cents, v_days, v_dim);
  v_trk := public.calc_prorated_fee(t.tracker_fee_cents, v_days, v_dim);
  if v_ins = 0 and v_trk = 0 then return null; end if;

  insert into owner_invoices (owner_id, vehicle_id, kind, period_month, days_billed, days_in_month,
                              billing_date, retry_on, status, created_by)
  values (v.owner_id, p_vehicle, 'monthly', v_month, v_days, v_dim,
          greatest(app.billing_date(v_month), app.today()), null, 'draft', p_by)
  returning id into v_id;

  insert into owner_invoice_lines (owner_invoice_id, kind, description, amount_cents, hst_applies, hst_cents) values
    (v_id, 'insurance_fee', format('Insurance Fee, %s (%s of %s days)', to_char(v_month, 'FMMonth YYYY'), v_days, v_dim),
           v_ins, true, public.calc_hst(v_ins, v_hst)),
    (v_id, 'tracker_fee', format('Tracker Fee, %s (%s of %s days)', to_char(v_month, 'FMMonth YYYY'), v_days, v_dim),
           v_trk, true, public.calc_hst(v_trk, v_hst));

  -- The prepaid first month pays the enrollment month; the unused part is credited to the next charge.
  -- The prepaid last month pays the exit month's Insurance Fee; the unused part is refunded.
  v_left := v_ins;
  for p in select * from vehicle_prepaids
            where vehicle_id = p_vehicle and remaining_cents > 0
              and (kind = 'first_month_insurance'
                   or (kind = 'last_month_insurance' and v_end is not null and app.month_start(v_end) = v_month))
            order by kind   -- first month before last month
  loop
    v_use := least(p.remaining_cents, v_left);
    if v_use > 0 then
      insert into owner_invoice_lines (owner_invoice_id, kind, description, amount_cents, hst_applies, hst_cents, vehicle_prepaid_id)
      values (v_id, 'prepaid_credit',
              case p.kind when 'first_month_insurance' then 'Prepaid first month''s Insurance Fee applied'
                          else 'Prepaid last month''s Insurance Fee applied' end,
              -v_use, true, -public.calc_hst(v_use, v_hst), p.id);
      update vehicle_prepaids set applied_cents = applied_cents + v_use where id = p.id;
      v_left := v_left - v_use;
    end if;
    if p.kind = 'last_month_insurance' then
      update vehicle_prepaids set refund_due_since = v_end where id = p.id and remaining_cents > 0;
    end if;
  end loop;
  return v_id;
end $$;

-- The run on the 15th: this month for every vehicle, plus last month for a vehicle enrolled
-- after last month's run. Idempotent. Turo-Only and shareholder-owned vehicles are skipped.
create or replace function app.generate_owner_invoices(p_month date, p_by uuid default null)
returns integer language plpgsql security definer set search_path = public, app as $$
declare
  v_month date := app.month_start(p_month);
  r record;
  n integer := 0;
begin
  for r in select v.id from vehicles v
            where v.enrollment_date is not null and v.billing_case in ('managed', 'self_managed')
            order by v.id
  loop
    if app.generate_owner_invoice(r.id, (v_month - interval '1 month')::date, p_by) is not null then n := n + 1; end if;
    if app.generate_owner_invoice(r.id, v_month, p_by) is not null then n := n + 1; end if;
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------- other deductions (section 2)
-- The only things besides unpaid Fees and Late Fees that may come off a payout.
create table owner_deductions (
  id            uuid primary key default gen_random_uuid(),
  owner_id      uuid not null references owners (id),
  vehicle_id    uuid references vehicles (id),
  kind          text not null check (kind in (
                  'plate_renewal', 'owner_booking_toll', 'owner_booking_ticket', 'lender_handover_cost',
                  'claim_shortfall', 'owner_booking_deductible', 'retransfer_fee',
                  'refund_share', 'chargeback_share', 'kickback_reversal', 'agreed_in_writing')),
  description   text not null,
  amount_cents  bigint not null check (amount_cents > 0),    -- as on the receipt, tax included
  hst_cents     bigint not null default 0,                   -- HST shown on the receipt, for the books
  incurred_on   date not null,
  booking_id    uuid references bookings (id),
  receipt_document_id uuid references documents (id),
  agreement_document_id uuid references documents (id),      -- the Owner's written agreement
  status        text not null default 'open' check (status in ('open', 'deducted', 'paid', 'waived')),
  owner_statement_id uuid,
  created_by    uuid references users (id),
  created_at    timestamptz not null default now(),
  check (kind <> 'agreed_in_writing' or agreement_document_id is not null)
);
create index owner_deductions_owner_idx on owner_deductions (owner_id, status);

-- ---------------------------------------------------------------- referral kickbacks (section 8)
create table referral_kickbacks (
  id                 uuid primary key default gen_random_uuid(),
  booking_id         uuid not null unique references bookings (id),
  renter_id          uuid not null references renters (id),
  vehicle_id         uuid not null references vehicles (id),    -- the booked vehicle bears it
  referrer_type      text not null check (referrer_type in ('owner', 'field_staff')),
  referrer_owner_id  uuid references owners (id),
  referrer_staff_id  uuid references users (id),
  base_cents         bigint not null check (base_cents >= 0),   -- the Rental Charge
  rate_bps           integer not null,
  amount_cents       bigint not null check (amount_cents >= 0),
  status             text not null default 'pending' check (status in ('pending', 'earned', 'paid', 'reversed')),
  earned_on          date,                                      -- the day the first rental was completed
  owner_statement_id uuid,                                      -- an Owner's is paid with the next payout
  payroll_period     date,                                      -- field staff: sent to payroll
  paid_at            timestamptz,
  reversed_at        timestamptz,
  reversal_reason    text,
  created_at         timestamptz not null default now(),
  check ((referrer_type = 'owner') = (referrer_owner_id is not null)),
  check ((referrer_type = 'field_staff') = (referrer_staff_id is not null))
);
create index referral_kickbacks_owner_idx on referral_kickbacks (referrer_owner_id, status);
create index referral_kickbacks_staff_idx on referral_kickbacks (referrer_staff_id, status);

-- Resolve "Referred by" to a person when the booking is made, and freeze it once confirmed.
create or replace function app.resolve_referrer() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_owner uuid;
  v_staff uuid;
begin
  if tg_op = 'UPDATE' and old.status not in ('tentative', 'pending_payment')
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
create trigger bookings_resolve_referrer before insert or update on bookings
  for each row execute function app.resolve_referrer();

-- Why a booking earns no kickback; null when it qualifies (section 8).
create or replace function app.kickback_ineligible_reason(p_booking uuid) returns text
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
begin
  select * into b from bookings where id = p_booking;
  if b.referrer_type is null then return 'not referred'; end if;
  if b.booking_type = 'owner' then return 'Owner Booking'; end if;
  if b.management_mode = 'self_managed' then return 'Self-Managed rental'; end if;
  if b.renews_booking_id is not null then return 'renewal'; end if;
  if b.status in ('cancelled', 'no_show', 'expired', 'declined') then return 'cancelled booking'; end if;
  if b.referrer_type = 'owner' and b.referrer_owner_id = b.owner_id then return 'referring Owner''s own vehicle'; end if;
  if b.referrer_type = 'field_staff' and not exists (
       select 1 from staff_profiles sp where sp.user_id = b.referrer_staff_id and sp.staff_type = 'field') then
    return 'virtual assistants earn none';
  end if;
  -- first rental only: the renter's first completed booking, with its extensions
  if exists (select 1 from bookings o
              where o.renter_id = b.renter_id and o.id <> b.id and o.booking_type <> 'owner'
                and o.status in ('returned', 'closed')
                and coalesce(o.checked_in_at, o.return_at) <= coalesce(b.checked_in_at, b.return_at)) then
    return 'not the renter''s first rental';
  end if;
  return null;
end $$;

-- ---------------------------------------------------------------- refunds spread over the booking's lines
-- "Retained amount: split across the booking's lines in proportion" (renter spec section 5).
-- The refund percentage applies to everything paid at booking, HST included, so each line and
-- its HST are refunded at the same percentage; a rounding cent goes to the largest line.
create or replace function app.allocate_refund(p_refund uuid) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  r refunds;
  v_sum bigint;
  n integer;
begin
  select * into r from refunds where id = p_refund;
  if r.refund_bps is null then
    raise exception 'Refund % has no percentage to allocate by', p_refund using errcode = '23514';
  end if;
  delete from refund_allocations where refund_id = p_refund;
  insert into refund_allocations (refund_id, line_item_id, amount_cents, hst_cents)
  select p_refund, li.id, public.calc_bps(li.amount_cents, r.refund_bps), public.calc_bps(li.hst_cents, r.refund_bps)
    from booking_line_items li
   where li.booking_id = r.booking_id and li.stage in ('booking', 'extension')
     and li.charged_to_renter and li.voided_at is null;
  get diagnostics n = row_count;
  select coalesce(sum(amount_cents + hst_cents), 0) into v_sum from refund_allocations where refund_id = p_refund;
  if v_sum <> r.amount_cents and n > 0 then
    update refund_allocations set amount_cents = amount_cents + (r.amount_cents - v_sum)
     where id = (select id from refund_allocations where refund_id = p_refund order by amount_cents desc, id limit 1);
  end if;
  return n;
end $$;

-- ---------------------------------------------------------------- the booking split, from its line items
alter table booking_splits add column uncollected_cents bigint not null default 0;  -- Owner Revenue not yet collected
alter table booking_splits add column kickback_ineligible_reason text;

-- Recompute one booking's split (renter spec section 8; owner spec section 2).
-- Safe to call any number of times. Once the split is on a paid statement it is not rewritten:
-- a later refund or chargeback becomes a deduction on the Owner's next statement.
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

  select coalesce(sum(amount_cents) filter (where charge_type in ('rental_charge', 'non_refundable_discount', 'late_return_extra_days')), 0),
         coalesce(sum(amount_cents) filter (where charge_type = 'mileage_overage'), 0),
         coalesce(sum(amount_cents) filter (where revenue_class = 'company_only'), 0),
         coalesce(sum(amount_cents) filter (where revenue_class = 'pass_through'), 0),
         coalesce(sum(hst_cents) filter (where charged_to_renter), 0),
         coalesce(sum(amount_cents) filter (where revenue_class = 'owner_revenue' and not exists (
             select 1 from payments p where p.id = li.payment_id and p.status = 'succeeded')), 0)
    into v_rental, v_mileage, v_company, v_pass, v_hst, v_uncollected
    from booking_line_items li
   where li.booking_id = p_booking and li.voided_at is null and li.charged_to_renter;

  select coalesce(sum(ra.amount_cents) filter (where li.charge_type in ('rental_charge', 'non_refundable_discount', 'late_return_extra_days')), 0),
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

-- ---------------------------------------------------------------- monthly owner statement (section 5)
create table owner_statements (
  id                 uuid primary key default gen_random_uuid(),
  statement_number   text not null unique default ('ST-' || nextval('owner_statement_number_seq')),
  owner_id           uuid not null references owners (id),
  statement_month    date not null check (extract(day from statement_month) = 1),
  payout_date        date not null,                      -- the 10th of the following month
  status             text not null default 'draft' check (status in ('draft', 'approved', 'paid', 'void')),
  is_final           boolean not null default false,     -- the first 10th after the month of the Exit Date
  owner_revenue_cents     bigint not null default 0,
  revenue_share_cents     bigint not null default 0,
  net_earnings_cents      bigint not null default 0,
  deductions_cents        bigint not null default 0,     -- every vehicle's deductions
  vehicles_payable_cents  bigint not null default 0,
  arrears_moved_cents     bigint not null default 0,     -- arrears of one vehicle taken from another
  kickbacks_earned_cents  bigint not null default 0,
  hst_on_payout_cents     bigint not null default 0,     -- only when the Owner's HST number is on file
  balance_brought_forward_cents bigint not null default 0,  -- negative = debt
  payout_cents            bigint not null default 0 check (payout_cents >= 0),
  balance_carried_forward_cents bigint not null default 0 check (balance_carried_forward_cents <= 0),
  approved_by        uuid references users (id),
  approved_at        timestamptz,
  sent_at            timestamptz,                        -- T26
  document_id        uuid references documents (id),
  built_by           uuid references users (id),
  built_at           timestamptz not null default now(),
  unique (owner_id, statement_month),
  check (status not in ('approved', 'paid') or approved_by is not null)
);

create table owner_statement_vehicles (
  id                  uuid primary key default gen_random_uuid(),
  owner_statement_id  uuid not null references owner_statements (id) on delete cascade,
  vehicle_id          uuid not null references vehicles (id),
  owner_revenue_cents bigint not null default 0,
  revenue_share_cents bigint not null default 0,
  withheld_cents      bigint not null default 0,          -- Owner Revenue in an open dispute
  net_earnings_cents  bigint not null default 0,
  fees_deducted_cents bigint not null default 0,          -- unpaid Fees with their HST
  late_fees_deducted_cents bigint not null default 0,
  owner_costs_deducted_cents bigint not null default 0,
  refund_chargeback_deducted_cents bigint not null default 0,
  payable_cents       bigint not null default 0,          -- net earnings - deductions
  unique (owner_statement_id, vehicle_id)
);

create table owner_statement_lines (
  id                 uuid primary key default gen_random_uuid(),
  owner_statement_id uuid not null references owner_statements (id) on delete cascade,
  vehicle_id         uuid references vehicles (id),       -- null for an owner-level line
  line_type          text not null check (line_type in (
                       'rental', 'turo_trip', 'withheld', 'fees_deducted', 'owner_cost', 'refund_or_chargeback',
                       'arrears_moved', 'kickback_earned', 'hst_on_payout', 'balance_brought_forward')),
  description        text,
  booking_id         uuid references bookings (id),
  turo_trip_id       uuid references turo_trips (id),
  owner_invoice_id   uuid references owner_invoices (id),
  owner_deduction_id uuid references owner_deductions (id),
  referral_kickback_id uuid references referral_kickbacks (id),
  from_vehicle_id    uuid references vehicles (id),       -- arrears moved: the vehicle that owed
  starts_on          date,
  ends_on            date,
  rental_charge_cents   bigint,
  mileage_overage_cents bigint,
  refunds_cents         bigint,
  chargebacks_cents     bigint,
  kickback_cents        bigint,
  owner_revenue_cents   bigint,
  revenue_share_cents   bigint,
  turo_gross_cents      bigint,
  turo_fees_cents       bigint,
  fee_cents             bigint,                           -- Fees with HST
  late_fee_cents        bigint,
  amount_cents       bigint not null                      -- effect on the payout (negative = deduction)
);
create index owner_statement_lines_statement_idx on owner_statement_lines (owner_statement_id, vehicle_id);

alter table booking_splits add constraint booking_splits_statement_fk
  foreign key (owner_statement_id) references owner_statements (id);
alter table turo_trips add column owner_statement_id uuid references owner_statements (id);
alter table owner_deductions add constraint owner_deductions_statement_fk
  foreign key (owner_statement_id) references owner_statements (id);
alter table referral_kickbacks add constraint referral_kickbacks_statement_fk
  foreign key (owner_statement_id) references owner_statements (id);

-- ---------------------------------------------------------------- payouts
-- Every payment out to an Owner, field staff member or investor. An Admin approves each one.
create table payouts (
  id               uuid primary key default gen_random_uuid(),
  payee_type       text not null check (payee_type in ('owner', 'field_staff', 'investor')),
  owner_id         uuid references owners (id),
  staff_user_id    uuid references users (id),
  investor_id      uuid,                                  -- FK added in 0010
  kind             text not null check (kind in (
                     'owner_statement', 'turo_only_statement', 'prepaid_refund', 'total_loss_balance', 'claim_profit',
                     'kickback_payroll', 'investor_return', 'investor_redemption', 'other')),
  owner_statement_id uuid references owner_statements (id),
  claim_id         uuid,                                  -- FK added in 0008
  amount_cents     bigint not null check (amount_cents > 0),
  hst_cents        bigint not null default 0,             -- part of amount_cents that is HST
  currency         text not null default 'CAD',
  method           text not null default 'bank_transfer' check (method in ('bank_transfer', 'e_transfer', 'payroll')),
  scheduled_for    date not null,                         -- the 10th (Owners) or the 15th (investors)
  status           text not null default 'draft'
                   check (status in ('draft', 'pending_approval', 'approved', 'sent', 'paid', 'failed', 'cancelled')),
  prepared_by      uuid references users (id),
  approved_by      uuid references users (id),            -- an Admin, always
  approved_at      timestamptz,
  second_approved_by uuid references users (id),          -- payments needing both Principals
  requires_both_principals boolean not null default false,
  reference        text,                                  -- bank reference
  paid_at          timestamptz,
  failure_reason   text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  check ((payee_type = 'owner') = (owner_id is not null)),
  check ((payee_type = 'field_staff') = (staff_user_id is not null)),
  check ((payee_type = 'investor') = (investor_id is not null)),
  check (status not in ('approved', 'sent', 'paid') or approved_by is not null),
  check (not requires_both_principals or status not in ('approved', 'sent', 'paid')
         or (second_approved_by is not null and second_approved_by <> approved_by)),
  check (status <> 'paid' or paid_at is not null)
);
create unique index payouts_one_per_statement on payouts (owner_statement_id) where status <> 'cancelled';
create index payouts_owner_idx on payouts (owner_id, scheduled_for);
create index payouts_due_idx on payouts (scheduled_for, status);
create trigger payouts_updated before update on payouts for each row execute function app.set_updated_at();

-- Build (or rebuild while it is a draft) one Owner's statement for a month.
create or replace function app.build_owner_statement(p_owner uuid, p_month date, p_by uuid default null)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  v_month date := app.month_start(p_month);
  v_month_end date := (app.month_start(p_month) + interval '1 month - 1 day')::date;
  o owners;
  v_id uuid;
  v_status text;
  r record; inv record; other record;
  v_rev bigint; v_share bigint; v_withheld bigint; v_net bigint; v_avail bigint;
  v_take bigint; v_fee_part bigint; v_late_part bigint; v_need bigint;
  v_fees bigint; v_late bigint; v_costs bigint; v_refunds bigint;
  v_moved bigint := 0;
  v_kick bigint; v_hst bigint := 0; v_total bigint; v_payable bigint; v_net_all bigint;
begin
  select * into o from owners where id = p_owner;
  if not found then raise exception 'Owner % not found', p_owner; end if;

  select id, status into v_id, v_status from owner_statements where owner_id = p_owner and statement_month = v_month;
  if v_id is not null and v_status <> 'draft' then
    raise exception 'The % statement for this Owner is already %', to_char(v_month, 'YYYY-MM'), v_status using errcode = '23514';
  end if;
  if v_id is null then
    insert into owner_statements (owner_id, statement_month, payout_date, built_by)
    values (p_owner, v_month, app.payout_date(v_month), p_by) returning id into v_id;
  else
    delete from owner_statement_lines where owner_statement_id = v_id;
    delete from owner_statement_vehicles where owner_statement_id = v_id;
    update owner_statements set built_at = now(), built_by = p_by, payout_date = app.payout_date(v_month) where id = v_id;
  end if;

  -- bring every finished booking's split up to date first
  -- (its own vehicles' bookings, and bookings on other vehicles whose renter this Owner referred)
  for r in select b.id from bookings b
            where (b.owner_id = p_owner or b.referrer_owner_id = p_owner) and b.booking_type <> 'owner'
              and b.status in ('returned', 'closed', 'cancelled', 'no_show')
              and not exists (select 1 from booking_splits s where s.booking_id = b.id and s.owner_statement_id is not null)
  loop
    perform app.compute_booking_split(r.id);
  end loop;

  -- one block per vehicle with anything to show
  for r in
    select v.id as vehicle_id
      from vehicles v
     where v.owner_id = p_owner
       and (exists (select 1 from booking_splits s where s.vehicle_id = v.id and s.owner_id = p_owner
                      and s.owner_statement_id is null and s.payout_month <= v_month and s.status <> 'reversed' and s.uncollected_cents = 0)
         or exists (select 1 from turo_trips t where t.vehicle_id = v.id and t.owner_statement_id is null and t.statement_month <= v_month and t.received_at is not null)
         or exists (select 1 from owner_invoices i where i.vehicle_id = v.id and i.status in ('in_arrears', 'partially_deducted'))
         or exists (select 1 from owner_deductions d where d.vehicle_id = v.id and d.owner_id = p_owner and d.status = 'open' and d.incurred_on <= v_month_end))
     order by v.fleet_number nulls last, v.created_at, v.id
  loop
    -- each rental ended (and each cancellation that kept part of the rental charge)
    insert into owner_statement_lines (owner_statement_id, vehicle_id, line_type, description, booking_id, starts_on, ends_on,
        rental_charge_cents, mileage_overage_cents, refunds_cents, chargebacks_cents, kickback_cents,
        owner_revenue_cents, revenue_share_cents, amount_cents)
    select v_id, r.vehicle_id, 'rental', 'Booking ' || b.booking_number, b.id,
           app.local_date(b.pickup_at), s.counts_on,
           s.rental_charge_cents, s.mileage_overage_cents, s.refunded_cents, s.chargeback_cents, s.kickback_cents,
           s.owner_revenue_cents, s.company_share_cents, s.owner_payout_cents
      from booking_splits s join bookings b on b.id = s.booking_id
     where s.vehicle_id = r.vehicle_id and s.owner_id = p_owner and s.owner_statement_id is null
       and s.payout_month <= v_month and s.status <> 'reversed' and s.uncollected_cents = 0
     order by s.counts_on, b.booking_number;

    -- each Turo trip: the split applies to the Turo Payout
    insert into owner_statement_lines (owner_statement_id, vehicle_id, line_type, description, turo_trip_id, starts_on, ends_on,
        turo_gross_cents, turo_fees_cents, owner_revenue_cents, revenue_share_cents, amount_cents)
    select v_id, r.vehicle_id, 'turo_trip', 'Turo trip ' || t.turo_trip_ref, t.id,
           app.local_date(t.starts_at), app.local_date(t.ends_at),
           t.gross_cents, t.turo_fees_cents, t.net_payout_cents, t.revenue_share_cents, t.owner_payout_cents
      from turo_trips t
     where t.vehicle_id = r.vehicle_id and t.owner_statement_id is null and t.statement_month <= v_month and t.received_at is not null;

    select coalesce(sum(owner_revenue_cents), 0), coalesce(sum(revenue_share_cents), 0), coalesce(sum(amount_cents), 0)
      into v_rev, v_share, v_net
      from owner_statement_lines where owner_statement_id = v_id and vehicle_id = r.vehicle_id and line_type in ('rental', 'turo_trip');

    -- Owner Revenue in dispute is withheld from the payout
    select coalesce(sum(least(s.withheld_cents, s.owner_payout_cents)), 0) into v_withheld
      from booking_splits s
     where s.vehicle_id = r.vehicle_id and s.owner_id = p_owner and s.owner_statement_id is null
       and s.payout_month <= v_month and s.status <> 'reversed' and s.uncollected_cents = 0 and s.withheld_cents > 0;
    if v_withheld > 0 then
      insert into owner_statement_lines (owner_statement_id, vehicle_id, line_type, description, amount_cents)
      values (v_id, r.vehicle_id, 'withheld', 'Owner Revenue in dispute, withheld', -v_withheld);
      v_net := v_net - v_withheld;
    end if;

    -- unpaid Fees and Late Fees after a failed retry: from this vehicle's revenue
    v_avail := greatest(v_net, 0);
    v_fees := 0; v_late := 0;
    for inv in select * from owner_invoices i
                where i.vehicle_id = r.vehicle_id and i.status in ('in_arrears', 'partially_deducted') and i.balance_cents > 0
                order by i.billing_date, i.invoice_number
    loop
      v_take := least(inv.balance_cents, v_avail);
      if v_take > 0 then
        -- Fees (with HST) are settled before the Late Fee
        v_fee_part := least(v_take, greatest(inv.fees_cents + inv.hst_cents - inv.paid_cents - inv.deducted_cents, 0));
        v_late_part := v_take - v_fee_part;
        insert into owner_statement_lines (owner_statement_id, vehicle_id, line_type, description, owner_invoice_id,
            fee_cents, late_fee_cents, amount_cents)
        values (v_id, r.vehicle_id, 'fees_deducted', 'Invoice ' || inv.invoice_number, inv.id, v_fee_part, v_late_part, -v_take);
        v_fees := v_fees + v_fee_part; v_late := v_late + v_late_part;
        v_avail := v_avail - v_take;
      end if;
    end loop;

    -- Owner costs CarmaCars paid, and the Owner's share of an earlier refund or chargeback
    insert into owner_statement_lines (owner_statement_id, vehicle_id, line_type, description, owner_deduction_id, booking_id, amount_cents)
    select v_id, r.vehicle_id,
           case when d.kind in ('refund_share', 'chargeback_share') then 'refund_or_chargeback' else 'owner_cost' end,
           d.description, d.id, d.booking_id, -d.amount_cents
      from owner_deductions d
     where d.vehicle_id = r.vehicle_id and d.owner_id = p_owner and d.status = 'open' and d.incurred_on <= v_month_end;
    select coalesce(-sum(amount_cents) filter (where line_type = 'owner_cost'), 0),
           coalesce(-sum(amount_cents) filter (where line_type = 'refund_or_chargeback'), 0)
      into v_costs, v_refunds
      from owner_statement_lines where owner_statement_id = v_id and vehicle_id = r.vehicle_id;

    insert into owner_statement_vehicles (owner_statement_id, vehicle_id, owner_revenue_cents, revenue_share_cents,
        withheld_cents, net_earnings_cents, fees_deducted_cents, late_fees_deducted_cents,
        owner_costs_deducted_cents, refund_chargeback_deducted_cents, payable_cents)
    values (v_id, r.vehicle_id, v_rev, v_share, v_withheld, v_net, v_fees, v_late, v_costs, v_refunds,
            v_net - v_fees - v_late - v_costs - v_refunds);
  end loop;

  -- deductions not tied to a vehicle (a reversed kickback, an agreed amount)
  insert into owner_statement_lines (owner_statement_id, vehicle_id, line_type, description, owner_deduction_id, booking_id, amount_cents)
  select v_id, null, 'owner_cost', d.description, d.id, d.booking_id, -d.amount_cents
    from owner_deductions d
   where d.vehicle_id is null and d.owner_id = p_owner and d.status = 'open' and d.incurred_on <= v_month_end;

  -- Balance still left: a debt payable on demand, deducted from the Owner's other vehicles
  for inv in select i.*, i.balance_cents - coalesce((select -sum(l.amount_cents) from owner_statement_lines l
                                  where l.owner_statement_id = v_id and l.owner_invoice_id = i.id), 0) as still_owed
               from owner_invoices i
              where i.owner_id = p_owner and i.status in ('in_arrears', 'partially_deducted') and i.balance_cents > 0
              order by i.billing_date, i.invoice_number
  loop
    v_need := inv.still_owed;
    for other in select sv.vehicle_id,
                        sv.payable_cents - coalesce((select sum(-l.amount_cents) from owner_statement_lines l
                            where l.owner_statement_id = v_id and l.line_type = 'arrears_moved' and l.vehicle_id = sv.vehicle_id), 0) as free
                   from owner_statement_vehicles sv
                  where sv.owner_statement_id = v_id and sv.vehicle_id <> inv.vehicle_id
                  order by sv.payable_cents desc
    loop
      exit when v_need <= 0;
      v_take := least(v_need, greatest(other.free, 0));
      if v_take > 0 then
        insert into owner_statement_lines (owner_statement_id, vehicle_id, line_type, description, owner_invoice_id, from_vehicle_id, amount_cents)
        values (v_id, other.vehicle_id, 'arrears_moved', 'Arrears on invoice ' || inv.invoice_number, inv.id, inv.vehicle_id, -v_take);
        v_moved := v_moved + v_take;
        v_need := v_need - v_take;
      end if;
    end loop;
  end loop;

  -- Referral Kickbacks this Owner earned: paid with the next payout
  insert into owner_statement_lines (owner_statement_id, line_type, description, referral_kickback_id, booking_id,
      rental_charge_cents, amount_cents)
  select v_id, 'kickback_earned', 'Referral Kickback, booking ' || b.booking_number, k.id, k.booking_id, k.base_cents, k.amount_cents
    from referral_kickbacks k join bookings b on b.id = k.booking_id
   where k.referrer_owner_id = p_owner and k.status = 'earned' and k.owner_statement_id is null and k.earned_on <= v_month_end;
  select coalesce(sum(amount_cents), 0) into v_kick
    from owner_statement_lines where owner_statement_id = v_id and line_type = 'kickback_earned';

  select coalesce(sum(payable_cents), 0), coalesce(sum(net_earnings_cents), 0) into v_payable, v_net_all
    from owner_statement_vehicles where owner_statement_id = v_id;
  v_payable := v_payable - coalesce((select sum(-amount_cents) from owner_statement_lines
                                      where owner_statement_id = v_id and vehicle_id is null and line_type = 'owner_cost'), 0);

  -- HST is added only when the Owner's HST number is on file
  if o.hst_number is not null and btrim(o.hst_number) <> '' and v_net_all > 0 then
    v_hst := public.calc_hst(v_net_all, (app.settings(v_month)).hst_bps);
    insert into owner_statement_lines (owner_statement_id, line_type, description, amount_cents)
    values (v_id, 'hst_on_payout', 'HST on payout, registration ' || o.hst_number, v_hst);
  end if;
  if o.balance_carried_forward_cents <> 0 then
    insert into owner_statement_lines (owner_statement_id, line_type, description, amount_cents)
    values (v_id, 'balance_brought_forward', 'Balance brought forward', o.balance_carried_forward_cents);
  end if;

  v_total := v_payable - v_moved + v_kick + v_hst + o.balance_carried_forward_cents;

  update owner_statements st
     set owner_revenue_cents = coalesce((select sum(owner_revenue_cents) from owner_statement_vehicles where owner_statement_id = v_id), 0),
         revenue_share_cents = coalesce((select sum(revenue_share_cents) from owner_statement_vehicles where owner_statement_id = v_id), 0),
         net_earnings_cents = v_net_all,
         deductions_cents = coalesce((select sum(fees_deducted_cents + late_fees_deducted_cents + owner_costs_deducted_cents + refund_chargeback_deducted_cents)
                                        from owner_statement_vehicles where owner_statement_id = v_id), 0),
         vehicles_payable_cents = v_payable,
         arrears_moved_cents = v_moved,
         kickbacks_earned_cents = v_kick,
         hst_on_payout_cents = v_hst,
         balance_brought_forward_cents = o.balance_carried_forward_cents,
         payout_cents = greatest(v_total, 0),
         balance_carried_forward_cents = least(v_total, 0),
         is_final = not exists (select 1 from vehicles v where v.owner_id = p_owner and v.status not in ('exited', 'total_loss', 'declined'))
   where st.id = v_id;
  return v_id;
end $$;

-- An Admin approves the run: the draft becomes the record, deductions are applied and the payout is created.
create or replace function app.approve_owner_statement(p_statement uuid, p_admin uuid)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  st owner_statements;
  l record;
  v_payout uuid;
begin
  if not exists (select 1 from user_roles where user_id = p_admin and role = 'admin') then
    raise exception 'Only an Admin approves a payout run' using errcode = '42501';
  end if;
  select * into st from owner_statements where id = p_statement for update;
  if st.status <> 'draft' then
    raise exception 'Statement % is already %', st.statement_number, st.status using errcode = '23514';
  end if;

  for l in select owner_invoice_id, sum(-amount_cents) as taken
             from owner_statement_lines
            where owner_statement_id = p_statement and owner_invoice_id is not null
              and line_type in ('fees_deducted', 'arrears_moved')
            group by owner_invoice_id
  loop
    update owner_invoices
       set deducted_cents = deducted_cents + l.taken,
           status = case when balance_cents - l.taken <= 0 then 'deducted' else 'partially_deducted' end
     where id = l.owner_invoice_id;
  end loop;

  update owner_deductions d set status = 'deducted', owner_statement_id = p_statement
    from owner_statement_lines sl where sl.owner_statement_id = p_statement and sl.owner_deduction_id = d.id;
  update referral_kickbacks k set owner_statement_id = p_statement
    from owner_statement_lines sl where sl.owner_statement_id = p_statement and sl.referral_kickback_id = k.id;
  update booking_splits s set owner_statement_id = p_statement, status = case when s.status = 'provisional' then 'final' else s.status end
    from owner_statement_lines sl where sl.owner_statement_id = p_statement and sl.line_type = 'rental' and sl.booking_id = s.booking_id;
  update turo_trips t set owner_statement_id = p_statement
    from owner_statement_lines sl where sl.owner_statement_id = p_statement and sl.turo_trip_id = t.id;
  update owners set balance_carried_forward_cents = st.balance_carried_forward_cents where id = st.owner_id;

  update owner_statements set status = 'approved', approved_by = p_admin, approved_at = now() where id = p_statement;

  if st.payout_cents > 0 then
    insert into payouts (payee_type, owner_id, kind, owner_statement_id, amount_cents, hst_cents, method,
                         scheduled_for, status, prepared_by, approved_by, approved_at)
    select 'owner', st.owner_id,
           case when not exists (select 1 from vehicles v where v.owner_id = st.owner_id and v.management_mode <> 'turo_only')
                then 'turo_only_statement' else 'owner_statement' end,
           p_statement, st.payout_cents, st.hst_on_payout_cents, o.payout_method,
           st.payout_date, 'approved', st.built_by, p_admin, now()
      from owners o where o.id = st.owner_id
    returning id into v_payout;
  else
    -- nothing to transfer: kickbacks earned were set against what the Owner owes
    update referral_kickbacks set status = 'paid', paid_at = now()
     where owner_statement_id = p_statement and status = 'earned';
  end if;
  return v_payout;
end $$;

-- When the transfer is confirmed, the statement and the kickbacks on it are paid.
create or replace function app.payout_paid_effects() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.status = 'paid' and old.status <> 'paid' and new.owner_statement_id is not null then
    update owner_statements set status = 'paid' where id = new.owner_statement_id and status = 'approved';
    update referral_kickbacks set status = 'paid', paid_at = new.paid_at
     where owner_statement_id = new.owner_statement_id and status = 'earned';
  end if;
  return new;
end $$;
create trigger payouts_paid_effects after update of status on payouts
  for each row execute function app.payout_paid_effects();
